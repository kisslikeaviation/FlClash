import Flutter
import Mobile
import NetworkExtension
import WidgetKit

/// The iOS side of the channels Android's ServicePlugin serves. The app's own
/// Core answers while no tunnel runs; a running tunnel owns the Core state the
/// UI shows, so calls go to the extension until it stops.
final class CoreChannel {
    private static let prefix = "com.follow.clash"
    private static let eventPollInterval: TimeInterval = 0.5

    private let service: FlutterMethodChannel
    private let core: FlutterMethodChannel
    private var manager: NETunnelProviderManager?
    private var revision = 0
    private var runRequested = false
    private var tunnelBecameActive = false
    private var stopRequested = false
    private var pollTimer: Timer?
    private var statusObserver: NSObjectProtocol?

    init(messenger: FlutterBinaryMessenger) {
        MobileUsePrivateCache(Self.privateCacheDir.path, nil)
        service = FlutterMethodChannel(name: "\(Self.prefix)/service", binaryMessenger: messenger)
        core = FlutterMethodChannel(name: "\(Self.prefix)/core", binaryMessenger: messenger)
        service.setMethodCallHandler { [weak self] call, result in
            self?.onService(call, result)
        }
        core.setMethodCallHandler { [weak self] call, result in
            self?.onCore(call, result)
        }
        // A suspended app misses status changes made from Control Center.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.onStatusChanged() }
    }

    private static var privateCacheDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("core")
    }

    private var session: NETunnelProviderSession? {
        manager?.connection as? NETunnelProviderSession
    }

    private var isTunnelUp: Bool { session?.status == .connected }

    private var isTunnelLive: Bool {
        switch session?.status {
        case nil, .disconnected, .invalid: return false
        default: return true
        }
    }

    private func onService(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "homeDir":
            result(Tunnel.home.path)
        case "init":
            initialize(result)
        case "shutdown":
            MobileSetEventListener(nil)
            stopPolling()
            result(true)
        case "getRunTime":
            let date = session?.connectedDate
            result(date.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0)
        case "syncState":
            syncState(call.arguments as? String, result)
        case "start":
            revision = call.arguments as? Int ?? revision
            runRequested = true
            stopRequested = false
            tunnelBecameActive = false
            start(result)
        case "stop":
            revision = call.arguments as? Int ?? revision
            runRequested = false
            // A tunnel that is already down reports no change that would clear this.
            stopRequested = isTunnelLive
            session?.stopTunnel()
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func onCore(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard call.method == "invokeMethod" else {
            result(FlutterMethodNotImplemented)
            return
        }
        guard let data = call.arguments as? String else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Payload must be a string", details: nil))
            return
        }
        recordSetup(data)
        let reply: (Data?) -> Void = { response in
            DispatchQueue.main.async {
                result(response.map(FlutterStandardTypedData.init(bytes:)))
            }
        }
        if isTunnelUp && !Self.appCoreMethods.contains(Self.methodName(data) ?? "") {
            send(.invoke, Data(data.utf8), reply)
        } else {
            MobileInvokeMethod(data, ResultHandler(reply))
        }
    }

    // "initialized" asked of the extension answers for the wrong Core, and
    // parsing a profile there can take it past its memory limit.
    private static let appCoreMethods: Set<String> = [
        "core.init", "core.initialized",
        "config.validate", "config.decrypt", "config.read",
        "profile.base", "profile.outbounds", "profile.build",
        "proxy.validate", "proxy.convert",
        "shareLink.encode", "shareLink.decode",
        "filter.validate", "ruleSet.dump",
    ]

    // Dart encodes the method ahead of its arguments.
    private static func methodName(_ data: String) -> String? {
        guard let key = data.range(of: "\"method\":\""),
              let end = data[key.upperBound...].firstIndex(of: "\"")
        else { return nil }
        return String(data[key.upperBound..<end])
    }

    private func initialize(_ result: @escaping FlutterResult) {
        MobileSetEventListener(ResultHandler { [weak self] data in
            guard let data else { return }
            DispatchQueue.main.async { self?.emit(data) }
        })
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    result(error.localizedDescription)
                    return
                }
                self.manager = managers?.first
                self.observeStatus()
                result("")
            }
        }
    }

    private func syncState(_ json: String?, _ result: @escaping FlutterResult) {
        guard let json else {
            result("Invalid shared state")
            return
        }
        do {
            try Data(json.utf8).write(to: Tunnel.sharedState, options: .atomic)
            result("")
        } catch {
            result(error.localizedDescription)
        }
    }

    // syncState drops setupParams on purpose, so the extension takes the last
    // setup the Core was given.
    private func recordSetup(_ data: String) {
        guard data.contains("\"config.setup\""),
              let call = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              call["method"] as? String == "config.setup",
              let arguments = call["arguments"],
              let params = try? JSONSerialization.data(withJSONObject: arguments)
        else { return }
        try? params.write(to: Tunnel.setupParams, options: .atomic)
    }

    private func start(_ result: @escaping FlutterResult) {
        if let manager, manager.isEnabled {
            launch(manager, result)
            return
        }
        // The first save is what shows the system's "Add VPN Configuration" prompt.
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Tunnel.providerBundle
        proto.serverAddress = "FlClash"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "FlClash"
        manager.isEnabled = true
        manager.saveToPreferences { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.finishFailedStart(result)
                return
            }
            manager.loadFromPreferences { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.manager = manager
                    self.observeStatus()
                    self.launch(manager, result)
                }
            }
        }
    }

    private func launch(_ manager: NETunnelProviderManager, _ result: @escaping FlutterResult) {
        if session?.status == .connected {
            onStatusChanged()
            result(true)
            return
        }
        do {
            try manager.connection.startVPNTunnel()
            result(true)
        } catch {
            finishFailedStart(result)
        }
    }

    private func finishFailedStart(_ result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            self.runRequested = false
            result(false)
        }
    }

    private func observeStatus() {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager?.connection,
            queue: .main
        ) { [weak self] _ in self?.onStatusChanged() }
        onStatusChanged()
    }

    private func onStatusChanged() {
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: Tunnel.vpnControlKind)
        }
        switch session?.status {
        case .connected:
            tunnelBecameActive = true
            startPolling()
            // Control Center and Settings start the tunnel without the app.
            if !runRequested && !stopRequested {
                runRequested = true
                service.invokeMethod("started", arguments: nil)
            }
        case .connecting, .reasserting:
            tunnelBecameActive = true
        case .disconnected, .invalid:
            stopPolling()
            stopRequested = false
            // A tunnel still waiting to start reads as disconnected too, and
            // reporting that would cancel the start that was just requested.
            if runRequested && tunnelBecameActive {
                runRequested = false
                service.invokeMethod("stopped", arguments: revision)
            }
        default:
            break
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.eventPollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.send(.events, Data()) { response in
                guard let response else { return }
                let events = Tunnel.unframe(response)
                DispatchQueue.main.async { events.forEach { self?.emit($0) } }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func emit(_ data: Data) {
        service.invokeMethod("event", arguments: FlutterStandardTypedData(bytes: data))
    }

    private func send(_ kind: Tunnel.Message, _ payload: Data, _ reply: @escaping (Data?) -> Void) {
        var message = Data([kind.rawValue])
        message.append(payload)
        do {
            guard let session else {
                reply(nil)
                return
            }
            try session.sendProviderMessage(message, responseHandler: reply)
        } catch {
            reply(nil)
        }
    }
}

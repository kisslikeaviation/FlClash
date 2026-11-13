import Darwin
import Mobile
import NetworkExtension
import os

private struct VpnOptions: Decodable {
    var ipv6 = false
    var dnsHijacking = false
    var stack: String?
    var mtu = 0
    var congestionController: String?
}

private struct SharedState: Decodable {
    var vpnOptions: VpnOptions?
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let ipv4Address = "198.18.0.1"
    private static let ipv4Mask = "255.255.255.252"
    private static let ipv6Address = "fdfe:dcba:9876::1"
    private static let ipv6Prefix: NSNumber = 126
    private static let dns = "198.18.0.2"
    private static let dns6 = "fdfe:dcba:9876::2"
    private static let hijackAny = "0.0.0.0"
    private static let defaultMtu = 1500
    // The system kills the extension at its limit, so the runtime starts
    // collecting hard well below it.
    private static let memoryBudgetShare = 0.7
    private static let gcPercent: Int32 = 50
    private static let maxQueuedEvents = 256
    private static let eventSubscriberTimeout: TimeInterval = 10

    private let eventLock = NSLock()
    private var events: [Data] = []
    private var lastPoll = Date.distantPast

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        try? FileManager.default.removeItem(at: Tunnel.startError)
        MobileSetMemoryBudget(
            Int64(Double(memoryLimit()) * Self.memoryBudgetShare),
            Self.gcPercent
        )
        let vpn = Self.loadOptions()
        setTunnelNetworkSettings(Self.networkSettings(vpn)) { [self] error in
            if let error {
                completionHandler(error)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                completionHandler(startCore(vpn))
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        MobileStopListener()
        MobileStopTun()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let kind = messageData.first.flatMap(Tunnel.Message.init(rawValue:)) else {
            completionHandler?(nil)
            return
        }
        switch kind {
        case .invoke:
            let data = String(decoding: messageData.dropFirst(), as: UTF8.self)
            MobileInvokeMethod(data, ResultHandler { completionHandler?($0) })
        case .events:
            completionHandler?(drainEvents())
        }
    }

    private func startCore(_ vpn: VpnOptions) -> Error? {
        guard let setup = try? String(contentsOf: Tunnel.setupParams, encoding: .utf8) else {
            return Self.failure("No profile has been applied yet")
        }
        MobileSetEventListener(ResultHandler { [weak self] in self?.enqueue($0) })

        let done = DispatchSemaphore(value: 0)
        var message = ""
        MobileQuickSetup(Self.initParams, setup, ResultHandler { data in
            message = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            done.signal()
        })
        done.wait()
        if !message.isEmpty {
            return Self.failure(message)
        }

        guard let fd = Self.tunnelDescriptor() else {
            return Self.failure("No utun descriptor in the extension")
        }
        // The Core closes what it is handed, and NetworkExtension still owns this socket.
        let started = MobileStartTun(
            dup(fd),
            TunCallbacks(),
            "gvisor",
            Self.coreAddress(vpn),
            Self.coreDns(vpn),
            Self.coreOptions(vpn)
        )
        guard started else {
            return Self.failure("The Core rejected the tun descriptor")
        }
        MobileStartListener()
        return nil
    }

    private static func failure(_ message: String) -> Error {
        try? Data(message.utf8).write(to: Tunnel.startError, options: .atomic)
        return NSError(domain: "FlClash", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func loadOptions() -> VpnOptions {
        guard let data = try? Data(contentsOf: Tunnel.sharedState),
              let state = try? JSONDecoder().decode(SharedState.self, from: data)
        else { return VpnOptions() }
        return state.vpnOptions ?? VpnOptions()
    }

    private static var initParams: String {
        let params: [String: Any] = ["home-dir": Tunnel.home.path, "version": 0]
        let data = try? JSONSerialization.data(withJSONObject: params)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func mtu(_ vpn: VpnOptions) -> Int {
        vpn.mtu > 0 ? min(vpn.mtu, defaultMtu) : defaultMtu
    }

    private static func networkSettings(_ vpn: VpnOptions) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: [ipv4Address], subnetMasks: [ipv4Mask])
        ipv4.includedRoutes = [.default()]
        settings.ipv4Settings = ipv4
        var servers = [dns]
        if vpn.ipv6 {
            let ipv6 = NEIPv6Settings(addresses: [ipv6Address], networkPrefixLengths: [ipv6Prefix])
            ipv6.includedRoutes = [.default()]
            settings.ipv6Settings = ipv6
            servers.append(dns6)
        }
        let dnsSettings = NEDNSSettings(servers: servers)
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        settings.mtu = NSNumber(value: mtu(vpn))
        return settings
    }

    private static func coreAddress(_ vpn: VpnOptions) -> String {
        let ipv4 = "\(ipv4Address)/30"
        return vpn.ipv6 ? "\(ipv4),\(ipv6Address)/\(ipv6Prefix)" : ipv4
    }

    private static func coreDns(_ vpn: VpnOptions) -> String {
        if vpn.dnsHijacking { return hijackAny }
        return vpn.ipv6 ? "\(dns),\(dns6)" : dns
    }

    private static func coreOptions(_ vpn: VpnOptions) -> String {
        let options: [String: Any] = [
            "mtu": mtu(vpn),
            "congestion-controller": vpn.congestionController ?? "",
        ]
        let data = try? JSONSerialization.data(withJSONObject: options)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // NEPacketTunnelFlow has no public accessor for its socket.
    private static func tunnelDescriptor() -> Int32? {
        let sysprotoControl: Int32 = 2
        let utunOptIfname: Int32 = 2
        for fd: Int32 in 0..<1024 {
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var length = socklen_t(name.count)
            if getsockopt(fd, sysprotoControl, utunOptIfname, &name, &length) == 0,
               String(cString: name).hasPrefix("utun") {
                return fd
            }
        }
        return nil
    }

    private func memoryLimit() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint = status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
        return footprint + os_proc_available_memory()
    }

    // Nobody reads the queue while the app is suspended, and the memory it
    // would hold is the extension's to lose.
    private func enqueue(_ data: Data?) {
        guard let data else { return }
        eventLock.lock()
        defer { eventLock.unlock() }
        guard Date().timeIntervalSince(lastPoll) < Self.eventSubscriberTimeout else {
            events.removeAll()
            return
        }
        events.append(data)
        if events.count > Self.maxQueuedEvents {
            events.removeFirst(events.count - Self.maxQueuedEvents)
        }
    }

    private func drainEvents() -> Data {
        eventLock.lock()
        defer { eventLock.unlock() }
        lastPoll = Date()
        let framed = Tunnel.frame(events)
        events.removeAll()
        return framed
    }
}

private final class TunCallbacks: NSObject, MobileTunHandlerProtocol {
    // The extension's own sockets already stay outside the tunnel.
    func protect(_ fd: Int32, ret0_ returnPointer: UnsafeMutablePointer<ObjCBool>?) throws {
        returnPointer?.pointee = true
    }

    func resolvePackage(_ uid: Int32, error: NSErrorPointer) -> String { "" }

    func resolveUid(
        _ protocol_: Int32,
        source: String?,
        target: String?,
        ret0_ returnPointer: UnsafeMutablePointer<Int32>?
    ) throws {
        returnPointer?.pointee = -1
    }
}

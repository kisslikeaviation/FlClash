import AppIntents
import NetworkExtension
import SwiftUI
import WidgetKit

@main
struct ControlWidgetBundle: WidgetBundle {
    var body: some Widget {
        VpnControl()
    }
}

struct VpnControl: ControlWidget {
    static let kind = (Bundle.main.object(forInfoDictionaryKey: "FlClashAppID") as! String) + ".vpn"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { isOn in
            ControlWidgetToggle(isOn: isOn, action: ToggleVpnIntent()) {
                Label("FlClash", systemImage: isOn ? "bolt.shield.fill" : "bolt.shield")
            }
        }
        .displayName("FlClash")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }

        func currentValue() async throws -> Bool {
            guard let connection = try await tunnel()?.connection else { return false }
            return [.connected, .connecting, .reasserting].contains(connection.status)
        }
    }
}

struct ToggleVpnIntent: SetValueIntent {
    static var title: LocalizedStringResource = "FlClash"
    private static let settleAttempts = 25
    private static let settleInterval: Duration = .milliseconds(200)

    @Parameter(title: "Connected")
    var value: Bool

    func perform() async throws -> some IntentResult {
        guard let manager = try await tunnel() else { return .result() }
        if value {
            // The system ignores a start while the last stop is still running.
            await settle(manager.connection, on: .disconnected)
            try manager.connection.startVPNTunnel()
            await settle(manager.connection, on: .connected)
        } else {
            manager.connection.stopVPNTunnel()
            await settle(manager.connection, on: .disconnected)
        }
        return .result()
    }

    // The control reads its value back when this returns, so returning while
    // the tunnel is still changing would flip the toggle back.
    private func settle(_ connection: NEVPNConnection, on target: NEVPNStatus) async {
        for _ in 0..<Self.settleAttempts where connection.status != target {
            try? await Task.sleep(for: Self.settleInterval)
        }
    }
}

private func tunnel() async throws -> NETunnelProviderManager? {
    try await NETunnelProviderManager.loadAllFromPreferences().first
}

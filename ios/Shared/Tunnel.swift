import Foundation
import Mobile

enum Tunnel {
    static let appID = Bundle.main.object(forInfoDictionaryKey: "FlClashAppID") as! String
    static let group = "group.\(appID)"
    static let providerBundle = "\(appID).PacketTunnel"
    static let vpnControlKind = "\(appID).vpn"

    static var home: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)!
    }
    static var sharedState: URL { home.appendingPathComponent("shared-state.json") }
    static var setupParams: URL { home.appendingPathComponent("setup-params.json") }
    static var startError: URL { home.appendingPathComponent("Library/Caches/tunnel-error.txt") }

    // A provider message is one kind byte, then the payload.
    enum Message: UInt8 {
        case invoke = 0
        case events = 1
    }

    /// Core events travel as a 4-byte big-endian length before each one.
    static func frame(_ events: [Data]) -> Data {
        var out = Data()
        for event in events {
            var length = UInt32(event.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(event)
        }
        return out
    }

    static func unframe(_ data: Data) -> [Data] {
        var events: [Data] = []
        var offset = data.startIndex
        while offset + 4 <= data.endIndex {
            let length = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            guard offset + length <= data.endIndex else { break }
            events.append(data[offset..<offset + length])
            offset += length
        }
        return events
    }
}

final class ResultHandler: NSObject, MobileResultHandlerProtocol {
    private let body: (Data?) -> Void

    init(_ body: @escaping (Data?) -> Void) {
        self.body = body
    }

    func onResult(_ data: Data?) throws {
        body(data)
    }
}

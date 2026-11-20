import Foundation

/// Messages of the sender protocol, version 1 (docs/protocol.md). Encoded as one JSON object per WebSocket text frame.
public enum Message {
    public static let protocolVersion = 1

    /// `key` from club.json, `device` the pseudonym for an LJ Link that can approve (Pairing); either may be missing.
    case hello(key: String?, device: String?, name: String, software: String, app: String, names: Bool)
    case load(deck: Int, id: String, lengthMs: Int64, bpm: Double?, key: String?, title: String?, artist: String?)
    case waveform(deck: Int, id: String, kind: String, entries: Int, data: [UInt8])
    case position(deck: Int, id: String, ms: Int64?, playing: Bool, speed: Double?, source: String)
    case unload(deck: Int)
    case names(on: Bool)
    case ping
    case bye

    public var json: String {
        var o: [String: Any]
        switch self {
        case let .hello(key, device, name, software, app, names):
            o = ["type": "hello", "protocol": Message.protocolVersion, "name": String(name.prefix(64)),
                 "software": software, "app": app, "names": names]
            if let key, !key.isEmpty { o["key"] = key }
            if let device { o["device"] = device }
        case let .load(deck, id, lengthMs, bpm, key, title, artist):
            o = ["type": "load", "deck": deck, "id": id, "lengthMs": lengthMs]
            if let bpm { o["bpm"] = bpm }
            if let key { o["key"] = key }
            if let title { o["title"] = title }
            if let artist { o["artist"] = artist }
        case let .waveform(deck, id, kind, entries, data):
            o = ["type": "waveform", "deck": deck, "id": id, "kind": kind, "entries": entries,
                 "data": Data(data).base64EncodedString()]
            if kind == "detail" { o["fps"] = Waveforms.detailRate }
        case let .position(deck, id, ms, playing, speed, source):
            o = ["type": "position", "deck": deck, "id": id, "ms": ms.map { $0 as Any } ?? NSNull(), "playing": playing, "source": source]
            if let speed { o["speed"] = (speed * 10000).rounded() / 10000 }
        case let .unload(deck):
            o = ["type": "unload", "deck": deck]
        case let .names(on):
            o = ["type": "names", "on": on]
        case .ping:
            o = ["type": "ping"]
        case .bye:
            o = ["type": "bye"]
        }
        let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
        return String(decoding: d, as: UTF8.self)
    }
}

/// What LJ Link answers.
public enum Reply: Equatable {
    case welcome(club: String)
    /// LJ Link asks the LJ whether this Mac may send (approval without club.json).
    case pending
    case reject(reason: String)
    case pong
    case other(String)

    public static func parse(_ text: String) -> Reply {
        guard let d = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = o["type"] as? String else { return .other(text) }
        switch t {
        case "welcome": return .welcome(club: o["club"] as? String ?? "")
        case "pending": return .pending
        case "reject": return .reject(reason: o["reason"] as? String ?? "")
        case "pong": return .pong
        default: return .other(t)
        }
    }
}

/// Random id per loaded file (never the path, protocol: "id").
public func newTrackId() -> String {
    String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
}

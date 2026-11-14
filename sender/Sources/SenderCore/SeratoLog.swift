import Foundation

/// A track Serato loaded onto a deck, as its log reports it.
public struct DeckLoad: Equatable, Sendable {
    /// 1-based deck number (Serato logs deck_0 for deck 1).
    public let deck: Int
    public let file: URL
    public let sampleRate: Int
    public let samples: Int64
    public var lengthMs: Int64 { sampleRate > 0 ? samples * 1000 / Int64(sampleRate) : 0 }
}

/// Serato DJ Pro writes a log while it runs (`~/Music/_Serato_/Logs`, newest file behind the symlink `DJ.INFO`).
/// Loading a track to a deck produces a line with
/// `cache:///<file>:deck_<n>_instrumental?sample_rate=<rate>&length=<samples>` (seen with Serato DJ Pro 5.0.0).
/// Play, pause, loops and the position are not in the log.
public enum SeratoLog {
    static let load = try! NSRegularExpression(
        pattern: #"cache://(/.+?):deck_(\d+)_instrumental\?sample_rate=(\d+)&length=(\d+)"#)

    /// All deck loads in a piece of log text, in order.
    public static func loads(in text: String) -> [DeckLoad] {
        let ns = text as NSString
        return load.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let deck = Int(ns.substring(with: m.range(at: 2))),
                  let rate = Int(ns.substring(with: m.range(at: 3))),
                  let samples = Int64(ns.substring(with: m.range(at: 4))) else { return nil }
            let path = ns.substring(with: m.range(at: 1))
            return DeckLoad(deck: deck + 1, file: URL(fileURLWithPath: path), sampleRate: rate, samples: samples)
        }
    }

    /// The Serato folder of the user running the sender, if Serato was ever used here.
    public static func seratoFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let f = home.appendingPathComponent("Music/_Serato_", isDirectory: true)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    public static func isSeratoRunning() -> Bool {
        let out = Process()
        out.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        out.arguments = ["-x", "Serato DJ Pro"]
        out.standardOutput = FileHandle.nullDevice
        do { try out.run(); out.waitUntilExit(); return out.terminationStatus == 0 } catch { return false }
    }
}

/// Follows Serato's current log file and reports new deck loads. Call `poll()` regularly (e.g. every 0.5 s).
/// Starts at the end of the current log: tracks loaded before the sender started are reported once by `current()`.
public final class SeratoLogFollower {
    private let logs: URL
    private var file: URL?
    private var offset: UInt64 = 0
    /// Last load per deck, so a repeated log line for the same file is not reported twice.
    public private(set) var loaded: [Int: DeckLoad] = [:]

    public init(seratoFolder: URL) {
        logs = seratoFolder.appendingPathComponent("Logs", isDirectory: true)
    }

    /// The newest log: Serato points `DJ.INFO` at it; otherwise the most recently changed `.log`.
    func newestLog() -> URL? {
        let link = logs.appendingPathComponent("DJ.INFO")
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            let u = URL(fileURLWithPath: dest, relativeTo: logs).standardizedFileURL
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "log" }.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
    }

    /// Reads the whole current log once and returns the last track of each deck (tracks loaded before the start).
    public func current() -> [DeckLoad] {
        guard let f = newestLog(), let data = try? Data(contentsOf: f) else { return [] }
        file = f
        offset = UInt64(data.count)
        let text = String(decoding: data, as: UTF8.self)
        for l in SeratoLog.loads(in: text) { loaded[l.deck] = l }
        return loaded.keys.sorted().compactMap { loaded[$0] }
    }

    /// New loads since the last call. A new log file (Serato restarted) is read from its start.
    public func poll() -> [DeckLoad] {
        guard let f = newestLog() else { return [] }
        if f != file {
            file = f
            offset = 0
            loaded.removeAll()
        }
        guard let h = try? FileHandle(forReadingFrom: f) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0 }
        guard size > offset else { return [] }
        try? h.seek(toOffset: offset)
        guard let data = try? h.read(upToCount: Int(min(size - offset, 8 << 20))), !data.isEmpty else { return [] }
        // Only complete lines; the rest is read next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
        let chunk = data[data.startIndex...lastNewline]
        offset += UInt64(chunk.count)
        var out: [DeckLoad] = []
        for l in SeratoLog.loads(in: String(decoding: chunk, as: UTF8.self)) where loaded[l.deck] != l {
            loaded[l.deck] = l
            out.append(l)
        }
        return out
    }
}

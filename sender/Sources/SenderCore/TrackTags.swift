import AVFoundation
import Foundation

/// Title, artist, BPM and key from the audio file's own tags (what Serato wrote there). Reads tags only, no audio, and
/// never Serato's library database.
public struct TrackTags: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var bpm: Double?
    /// Camelot notation as Serato shows it ("6A"), converted from the musical key ("Gm") when needed.
    public var key: String?

    public init(title: String? = nil, artist: String? = nil, bpm: Double? = nil, key: String? = nil) {
        self.title = title
        self.artist = artist
        self.bpm = bpm
        self.key = key
    }

    public static func read(_ url: URL) -> TrackTags {
        if url.pathExtension.lowercased() == "flac", let t = flac(url) { return t }
        return avFoundation(url)
    }

    // MARK: FLAC (Vorbis comments; macOS does not hand these out through AVFoundation)

    static func flac(_ url: URL) -> TrackTags? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard (try? h.read(upToCount: 4)) == Data("fLaC".utf8) else { return nil }
        var last = false
        var guardBlocks = 0
        while !last, guardBlocks < 64 {
            guardBlocks += 1
            guard let head = try? h.read(upToCount: 4), head.count == 4 else { return nil }
            last = head[0] & 0x80 != 0
            let type = head[0] & 0x7F
            let len = Int(head[1]) << 16 | Int(head[2]) << 8 | Int(head[3])
            if type == 4 {
                guard let block = try? h.read(upToCount: len), block.count == len else { return nil }
                return vorbis(block)
            }
            guard let pos = try? h.offset() else { return nil }
            try? h.seek(toOffset: pos + UInt64(len))
        }
        return nil
    }

    /// Parses a Vorbis comment block: vendor string, count, then "KEY=value" entries (little endian lengths).
    static func vorbis(_ b: Data) -> TrackTags {
        let bytes = [UInt8](b)
        func u32(_ p: Int) -> Int? {
            guard p + 4 <= bytes.count else { return nil }
            return Int(bytes[p]) | Int(bytes[p + 1]) << 8 | Int(bytes[p + 2]) << 16 | Int(bytes[p + 3]) << 24
        }
        var t = TrackTags()
        guard let vendor = u32(0) else { return t }
        var p = 4 + vendor
        guard let count = u32(p) else { return t }
        p += 4
        for _ in 0..<min(count, 512) {
            guard let len = u32(p), p + 4 + len <= bytes.count else { break }
            let entry = String(decoding: bytes[(p + 4)..<(p + 4 + len)], as: UTF8.self)
            p += 4 + len
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let k = entry[..<eq].uppercased(), v = String(entry[entry.index(after: eq)...])
            switch k {
            case "TITLE": t.title = v
            case "ARTIST": t.artist = v
            case "BPM": t.bpm = Double(v.replacingOccurrences(of: ",", with: "."))
            case "INITIALKEY", "KEY": t.key = camelot(v)
            default: break
            }
        }
        return t
    }

    // MARK: MP3, AAC/M4A, AIFF, WAV through AVFoundation

    static func avFoundation(_ url: URL) -> TrackTags {
        let asset = AVURLAsset(url: url)
        var t = TrackTags()
        let done = DispatchSemaphore(value: 0)
        Task {
            var items: [AVMetadataItem] = []
            if let formats = try? await asset.load(.availableMetadataFormats) {
                for f in formats { items += (try? await asset.loadMetadata(for: f)) ?? [] }
            }
            for i in items {
                let id = i.identifier?.rawValue ?? ""
                let s = try? await i.load(.stringValue)
                switch true {
                case i.commonKey == .commonKeyTitle: t.title = t.title ?? s
                case i.commonKey == .commonKeyArtist: t.artist = t.artist ?? s
                case id.hasSuffix("TBPM"), id.lowercased().hasSuffix("tmpo"), id.lowercased().hasSuffix("bpm"):
                    if let s { t.bpm = t.bpm ?? Double(s) } else if let n = try? await i.load(.numberValue) { t.bpm = t.bpm ?? n.doubleValue }
                case id.hasSuffix("TKEY"), id.lowercased().hasSuffix("initialkey"):
                    if let s { t.key = t.key ?? camelot(s) }
                default: break
                }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        return t
    }

    // MARK: Key notation

    static let camelotOf: [String: String] = [
        "Abm": "1A", "G#m": "1A", "Ebm": "2A", "D#m": "2A", "Bbm": "3A", "A#m": "3A", "Fm": "4A", "Cm": "5A", "Gm": "6A",
        "Dm": "7A", "Am": "8A", "Em": "9A", "Bm": "10A", "F#m": "11A", "Gbm": "11A", "Dbm": "12A", "C#m": "12A",
        "B": "1B", "Cb": "1B", "F#": "2B", "Gb": "2B", "Db": "3B", "C#": "3B", "Ab": "4B", "G#": "4B", "Eb": "5B", "D#": "5B",
        "Bb": "6B", "A#": "6B", "F": "7B", "C": "8B", "G": "9B", "D": "10B", "A": "11B", "E": "12B",
    ]

    /// "Gm" → "6A", "G minor" → "6A", "6A" stays. Unknown text is passed on unchanged.
    public static func camelot(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.range(of: #"^(1[0-2]|[1-9])[ABab]$"#, options: .regularExpression) != nil { return s.uppercased() }
        var k = s.replacingOccurrences(of: " minor", with: "m").replacingOccurrences(of: " major", with: "")
            .replacingOccurrences(of: "min", with: "m").replacingOccurrences(of: "maj", with: "")
            .replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        if k.count >= 1 { k = k.prefix(1).uppercased() + k.dropFirst() }
        return camelotOf[k] ?? s
    }
}

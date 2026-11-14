import Foundation

/// Makes log lines safe for a problem report: no track or file names, no paths of the user's folder.
public enum LogPrivacy {
    /// "Deck 1: <file> geladen, 235 s" keeps only the deck and the length; a waveform error keeps only its kind; any
    /// audio file name left (".flac", ".mp3" …) is replaced; the home folder becomes "~".
    public static func clean(_ line: String, home: String = NSHomeDirectory()) -> String {
        var s = line
        if let r = s.range(of: #"Deck (\d+): .* geladen, "#, options: .regularExpression) {
            let deck = s[r].split(separator: ":").first ?? "Deck"
            s.replaceSubrange(r, with: "\(deck): Track geladen, ")
        }
        // Older wording of the waveform error: "cannot open <file>: …" / "no audio in <file>".
        s = s.replacingOccurrences(of: #"cannot open (?!the file)[^)]*"#, with: "cannot open the file", options: .regularExpression)
        s = s.replacingOccurrences(of: #"no audio in (?!the file)[^)]*"#, with: "no audio in the file", options: .regularExpression)
        // Any audio file name that slipped through (a name may contain spaces: up to the extension).
        // From the last "/" or ":" on, brackets included ("Track (Extended Mix).flac").
        s = s.replacingOccurrences(of: #"[^/:\n]+\.(?i:flac|mp3|wav|aiff?|m4a|m4p|aac|ogg|alac|mp4|wma)\b"#,
                                   with: "<file>", options: .regularExpression)
        if !home.isEmpty { s = s.replacingOccurrences(of: home, with: "~") }
        return s
    }
}

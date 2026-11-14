import Foundation

/// What LJ Link writes onto the club's USB stick next to the sender ("USB-Stick für DJs vorbereiten", concept 3.1).
/// With it the sender connects to the club's LJ Link at once, without a pairing code.
public struct ClubConfig: Codable, Equatable, Sendable {
    /// Format version of club.json.
    public var version: Int
    /// Shown to the DJ: "Verbunden mit LJ Link – <club>".
    public var club: String
    /// Addresses of the booth computer (IPv4 or host names), tried in order.
    public var hosts: [String]
    public var port: Int
    /// Random key LJ Link accepts for senders. Not a password of anyone; a new key makes old sticks invalid.
    public var key: String

    public static let fileName = "club.json"

    public init(version: Int, club: String, hosts: [String], port: Int, key: String) {
        self.version = version
        self.club = club
        self.hosts = hosts
        self.port = port
        self.key = key
    }

    /// Looks for club.json next to the app bundle (on the stick), or next to the executable during development.
    public static func load(near bundle: Bundle = .main) -> ClubConfig? {
        var dirs = [bundle.bundleURL.deletingLastPathComponent()]
        if let exe = bundle.executableURL { dirs.append(exe.deletingLastPathComponent()) }
        for d in dirs {
            let f = d.appendingPathComponent(fileName)
            if let data = try? Data(contentsOf: f), let c = try? JSONDecoder().decode(ClubConfig.self, from: data) { return c }
        }
        return nil
    }
}

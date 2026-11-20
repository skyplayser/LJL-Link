import Foundation
import Network

/// An LJ Link LJL Link can send to: from club.json (address, port) or found by Bonjour (with what its TXT says).
public struct Place: Equatable, Sendable {
    public var host: String
    public var port: Int
    /// TXT `booth`: the id this LJ Link derives approvals from (protocol: approval without club.json).
    public var booth: String?
    /// TXT `pair=1`: this LJ Link can approve a Mac without the club key.
    public var pair: Bool
    /// Bonjour name, e.g. "LJ Link (booth-pc)".
    public var name: String?
    public init(host: String, port: Int, booth: String? = nil, pair: Bool = false, name: String? = nil) {
        self.host = host; self.port = port; self.booth = booth; self.pair = pair; self.name = name
    }
}

/// Finds LJ Link in the local network via Bonjour (`_ljlink._tcp`, TXT `sender=1`), so LJL Link connects without
/// club.json, or when the booth computer's address changed since the stick was prepared (DHCP). LJ Link decides: with
/// the club key, a Mac it approved before, or after the LJ allows it (TXT `pair=1`).
public final class BoothFinder {
    private let queue = DispatchQueue(label: "ljlink.boothfinder")
    private var browser: NWBrowser?
    private var resolving: [NWEndpoint: NWConnection] = [:]
    private var found: [String: Place] = [:]
    /// What the TXT record says, per endpoint, until the address is known.
    private var txt: [String: (booth: String?, pair: Bool, name: String?)] = [:]
    private let lock = NSLock()

    public init() {}

    /// Development: what Bonjour finds (LJL_DEBUG_BONJOUR=1).
    static let debug = ProcessInfo.processInfo.environment["LJL_DEBUG_BONJOUR"] == "1"

    /// Development and tests only: use just the LJ Link on this port (LJL_ONLY_PORT=8097), so a test never reaches the
    /// live LJ Link on 8080.
    static let onlyPort = ProcessInfo.processInfo.environment["LJL_ONLY_PORT"].flatMap { Int($0) }

    /// The LJ Links found so far (IPv4).
    public var booths: [Place] {
        lock.lock(); defer { lock.unlock() }
        return found.values.filter { BoothFinder.onlyPort == nil || $0.port == BoothFinder.onlyPort }
            .sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    }

    public func start() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_ljlink._tcp", domain: nil), using: .tcp)
        b.stateUpdateHandler = { state in
            if BoothFinder.debug { FileHandle.standardError.write(Data("bonjour browser: \(state)\n".utf8)) }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for r in results {
                if BoothFinder.debug { FileHandle.standardError.write(Data("bonjour result: \(r.endpoint) \(r.metadata)\n".utf8)) }
                var booth: String?, pair = false
                if case .bonjour(let t) = r.metadata {
                    if t["sender"] != "1" { continue }
                    booth = t["booth"].flatMap { $0.isEmpty ? nil : String($0.prefix(64)) }
                    pair = t["pair"] == "1"
                }
                var name: String?
                if case .service(let n, _, _, _) = r.endpoint { name = n }
                self.lock.lock()
                self.txt["\(r.endpoint)"] = (booth, pair, name)
                if var p = self.found["\(r.endpoint)"] { p.booth = booth; p.pair = pair; p.name = name; self.found["\(r.endpoint)"] = p }
                self.lock.unlock()
                self.resolve(r.endpoint)
            }
        }
        b.start(queue: queue)
        browser = b
    }

    public func stop() {
        browser?.cancel()
        queue.async { self.resolving.values.forEach { $0.cancel() }; self.resolving.removeAll() }
    }

    /// Opens a TCP connection to the service once to learn its IPv4 address and port, then closes it.
    private func resolve(_ endpoint: NWEndpoint) {
        guard resolving[endpoint] == nil else { return }
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: endpoint, using: params)
        resolving[endpoint] = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            if BoothFinder.debug { FileHandle.standardError.write(Data("bonjour resolve \(endpoint): \(state) \(String(describing: c.currentPath?.remoteEndpoint))\n".utf8)) }
            switch state {
            case .ready:
                if case .hostPort(let host, let port) = c.currentPath?.remoteEndpoint, case .ipv4(let a) = host {
                    // "10.69.10.146%en8": the interface part is no valid part of a URL.
                    let h = "\(a)".components(separatedBy: "%")[0]
                    self.lock.lock()
                    let t = self.txt["\(endpoint)"]
                    self.found["\(endpoint)"] = Place(host: h, port: Int(port.rawValue), booth: t?.booth, pair: t?.pair ?? false, name: t?.name)
                    self.lock.unlock()
                }
                c.cancel()
            case .failed, .cancelled:
                // Looked at again with the next browse change.
                self.queue.asyncAfter(deadline: .now() + 10) { self.resolving.removeValue(forKey: endpoint) }
            default:
                break
            }
        }
        c.start(queue: queue)
    }
}

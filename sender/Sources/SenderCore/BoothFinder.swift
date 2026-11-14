import Foundation
import Network

/// Finds LJ Link in the local network via Bonjour (`_ljlink._tcp`, TXT `sender=1`), so LJL Link connects even when the
/// booth computer's address changed since the stick was prepared (DHCP). The club key still decides: a different LJ Link
/// answers `reject key`, and the next one is tried.
public final class BoothFinder {
    private let queue = DispatchQueue(label: "ljlink.boothfinder")
    private var browser: NWBrowser?
    private var resolving: [NWEndpoint: NWConnection] = [:]
    private var found: [String: (host: String, port: Int)] = [:]
    private let lock = NSLock()

    public init() {}

    /// Development: what Bonjour finds (LJL_DEBUG_BONJOUR=1).
    static let debug = ProcessInfo.processInfo.environment["LJL_DEBUG_BONJOUR"] == "1"

    /// The LJ Links found so far, as "host:port" pairs (IPv4).
    public var booths: [(host: String, port: Int)] {
        lock.lock(); defer { lock.unlock() }
        return found.values.sorted { $0.host < $1.host }
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
                if case .bonjour(let txt) = r.metadata, txt["sender"] != "1" { continue }
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
                    self.lock.lock(); self.found["\(endpoint)"] = (h, Int(port.rawValue)); self.lock.unlock()
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

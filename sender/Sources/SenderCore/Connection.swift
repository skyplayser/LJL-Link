import Foundation

/// The WebSocket connection to LJ Link. Tries the club's hosts in order, says hello, keeps the link alive with a ping
/// every 5 s and reconnects after a loss. On every (re)connect it asks `resend` for the current deck state.
public final class Connection: NSObject, URLSessionWebSocketDelegate {
    public enum State: Equatable, CustomStringConvertible {
        case connecting(String)
        case connected(club: String)
        case rejected(String)
        case waiting(String)
        public var description: String {
            switch self {
            case .connecting(let h): return "verbinde mit \(h) …"
            case .connected(let c): return "verbunden mit LJ Link – \(c)"
            case .rejected(let r): return "abgelehnt (\(r))"
            case .waiting(let w): return "warte: \(w)"
            }
        }
    }

    private let config: ClubConfig
    private let hello: () -> Message
    private let resend: () -> [Message]
    private let onState: (State) -> Void
    private let queue = DispatchQueue(label: "ljlink.connection")
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var hostIndex = 0
    /// How many places the last attempt chose from (club.json plus Bonjour).
    private var placeCount = 1
    /// One round = every place tried once. A refusal in the round (e.g. "key") is what the DJ sees at its end, then the
    /// long pause; a place that is not reachable never hides it (QS 11, SOLLTE 1).
    private var triedInRound = 0
    private var refusedInRound: String?
    /// More places to try after the ones in club.json: LJ Links found via Bonjour (BoothFinder).
    public var moreHosts: () -> [(host: String, port: Int)] = { [] }
    private var welcomed = false
    private var stopped = false
    private var pingTimer: DispatchSourceTimer?
    private var lastPong = Date.distantPast

    public init(config: ClubConfig, hello: @escaping () -> Message, resend: @escaping () -> [Message],
                onState: @escaping (State) -> Void) {
        self.config = config
        self.hello = hello
        self.resend = resend
        self.onState = onState
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    public func start() { queue.async { self.connect() } }

    public func stop() {
        queue.sync {
            stopped = true
            if welcomed { sendNow(.bye) }
            pingTimer?.cancel()
            task?.cancel(with: .goingAway, reason: nil)
        }
    }

    /// Sends a deck message if LJ Link has welcomed us; otherwise it is dropped (resend() delivers the state later).
    public func send(_ m: Message) { queue.async { if self.welcomed { self.sendNow(m) } } }

    private func sendNow(_ m: Message) {
        task?.send(.string(m.json)) { [weak self] err in
            if err != nil { self?.queue.async { self?.lost("send failed") } }
        }
    }

    private func connect() {
        guard !stopped else { return }
        // The addresses from club.json first, then LJ Links found in the network (the booth's address may have changed).
        var places = config.hosts.map { (host: $0, port: config.port) }
        for p in moreHosts() where !places.contains(where: { $0.host == p.host && $0.port == p.port }) { places.append(p) }
        guard !places.isEmpty else {
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.connect() }
            return
        }
        placeCount = places.count
        let (host, port) = places[hostIndex % places.count]
        guard let url = URL(string: "ws://\(host):\(port)/sender") else {
            // An address that makes no URL: the next one (never stop trying).
            hostIndex += 1
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
            return
        }
        welcomed = false
        onState(.connecting("\(host):\(port)"))
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 4 << 20
        task = t
        t.resume()
        t.send(.string(hello().json)) { [weak self] err in
            if err != nil { self?.queue.async { self?.lost("\(host) nicht erreichbar") } }
        }
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard t === self.task else { return }
                switch result {
                case .failure:
                    self.lost("Verbindung getrennt")
                case .success(let msg):
                    if case .string(let s) = msg { self.handle(Reply.parse(s)) }
                    self.receive(t)
                }
            }
        }
    }

    private func handle(_ r: Reply) {
        switch r {
        case .welcome(let club):
            welcomed = true
            triedInRound = 0
            refusedInRound = nil
            lastPong = Date()
            onState(.connected(club: club.isEmpty ? config.club : club))
            for m in resend() { sendNow(m) }
            startPing()
        case .reject(let reason):
            welcomed = false
            onState(.rejected(reason))
            task?.cancel(with: .normalClosure, reason: nil)
            task = nil
            // Another club's LJ Link in the same network refuses the key: try the next place soon (QS 10, MUSS 3; it
            // used to ask the same one every 60 s and never reach the right one).
            next(why: "abgelehnt: \(reason)", refused: reason)
        case .pong:
            lastPong = Date()
        case .other:
            break
        }
    }

    private func startPing() {
        pingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self, self.welcomed else { return }
            if Date().timeIntervalSince(self.lastPong) > 15 { self.lost("keine Antwort"); return }
            self.sendNow(.ping)
        }
        t.resume()
        pingTimer = t
    }

    private func lost(_ why: String) {
        guard !stopped, task != nil else { return }
        pingTimer?.cancel()
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        welcomed = false
        next(why: why, refused: nil)
    }

    /// The next place. After a full round with a refusal: show it and wait long (a wrong key stays wrong; the LJ may
    /// make a new stick meanwhile). Within a round the refusal stays on screen, a "not reachable" never replaces it.
    private func next(why: String, refused: String?) {
        if let refused { refusedInRound = refused }
        hostIndex += 1
        triedInRound += 1
        if triedInRound >= max(1, placeCount) {
            triedInRound = 0
            if let r = refusedInRound {
                refusedInRound = nil
                onState(.rejected(r))
                retry(after: r == "key" ? 60 : 10, why: "abgelehnt: \(r)", report: false)
            } else {
                retry(after: 2, why: why)
            }
        } else {
            retry(after: 2, why: why, report: refusedInRound == nil)
        }
    }

    private func retry(after seconds: Double, why: String, report: Bool = true) {
        if report { onState(.waiting(why)) }
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.stopped, self.task == nil else { return }
            self.connect()
        }
    }
}

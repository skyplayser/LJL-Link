import Darwin
import Foundation

/// The suite chat (Alpha, LJ Link docs/suite-chat.md): one room for every suite program in the network, without a host,
/// over UDP multicast. `SuiteChat` is the room as this program sees it; `SuiteChat.Net` is the network side. Chat text is
/// never logged, never written to a file and never part of a problem report.
public final class SuiteChat {
    public static let group = "239.255.76.76"
    public static let port: UInt16 = 47676
    public static let maxText = 500
    public static let maxNick = 24
    static let maxKept = 200
    static let maxPeers = 50
    static let burst = 10
    static let burstWindow: TimeInterval = 10
    static let hereEvery: TimeInterval = 5
    static let goneAfter: TimeInterval = 15
    static let historyAnswer = 20
    /// QS 10: a `history?` is answered at most once in 10 s, from anyone; at most 64 datagrams wait to be sent.
    static let historyCooldown: TimeInterval = 10
    static let maxPending = 64
    /// QS 10: at most 3 EMERGENCY pop-ups per peer in 60 s; more are shown as normal messages.
    static let urgentBurst = 3
    static let urgentWindow: TimeInterval = 60
    /// `at` beyond this (the year 2100) or not a finite number is replaced by the receiver's own clock (QS 10, MUSS 1).
    static let maxAtMs = 4_102_444_800_000.0
    static let maxDatagram = 8 * 1024

    /// Where datagrams go; `delay` for the second copy of a message and the spaced history answer.
    public protocol Out: AnyObject {
        func send(_ json: String, delay: TimeInterval)
    }

    public struct Line: Identifiable, Equatable, Sendable {
        public let id: String
        public let nick: String
        public let where_: String
        public let app: String
        public let text: String
        public let at: Date
        public let mine: Bool
        /// EMERGENCY: shown as a pop-up (never for a history answer).
        public let urgent: Bool
        /// Came as history (`old`): never counted as unread, never a pop-up.
        public var old: Bool = false
    }

    public struct Member: Equatable, Sendable {
        public let nick: String
        public let where_: String
        public let app: String
        public init(nick: String, where_: String = "", app: String) { self.nick = nick; self.where_ = where_; self.app = app }
    }

    /// "DJ David (DJ Booth) · LJL Link"
    public static func who(_ nick: String, _ where_: String, _ app: String) -> String {
        (nick.isEmpty ? (app.isEmpty ? "?" : app) : nick) + (where_.isEmpty ? "" : " (\(where_))") + (!nick.isEmpty && !app.isEmpty ? " · \(app)" : "")
    }

    private final class PeerState {
        var nick = ""
        var where_ = ""
        var app = ""
        var lastSeen: TimeInterval = 0
        var times: [TimeInterval] = []
        var urgentTimes: [TimeInterval] = []
    }

    public let peer: String
    let app: String
    weak var out: Out?
    private let lock = NSLock()
    private var on = false
    private var nick = ""
    private var where_ = ""
    private var seq = 0
    private var lastHere: TimeInterval = -.infinity
    private var historyUntil: TimeInterval = -.infinity
    /// When this program joined, and whether a history answer came since (else it asks once more after 12 s).
    private var joinedAt: TimeInterval = -.infinity
    private var gotHistory = false
    private var askedAgain = false
    private var lastHistoryAnswer: TimeInterval = -.infinity
    /// History messages from senders not in the room (outside the own 5-s window): together 10 in 10 s.
    private var strangerTimes: [TimeInterval] = []
    private var lines: [Line] = []
    private var ids: [String] = []
    private var idSet = Set<String>()
    private var peers: [String: PeerState] = [:]
    /// Called after every change (on the caller's or the network's queue).
    public var onChange: (() -> Void)?

    public init(app: String, out: Out?, peer: String = SuiteChat.newPeerId()) {
        self.app = app
        self.out = out
        self.peer = peer
    }

    /// Strict JSON types (spec): a number, never a boolean (`true` would read as 1).
    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// Strict JSON types (spec): only a real `true` counts – not 1, not "true".
    static func isTrue(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID() && n.boolValue
    }

    public static func newPeerId() -> String {
        let chars = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return String((0..<12).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    // MARK: this program

    public func setOn(_ value: Bool, now: TimeInterval = Date().timeIntervalSince1970) {
        lock.lock()
        guard value != on else { lock.unlock(); return }
        on = value
        if on {
            here(now)
            historyUntil = now + 5
            joinedAt = now
            gotHistory = false
            askedAgain = false
            out?.send(base("history?"), delay: 0)
        } else {
            out?.send(base("bye"), delay: 0)
            peers.removeAll()
            // Off forgets the messages, too (privacy); switched on again, the others send the history.
            lines.removeAll()
            ids.removeAll()
            idSet.removeAll()
        }
        lock.unlock()
        onChange?()
    }

    public func setNick(_ value: String, now: TimeInterval = Date().timeIntervalSince1970) {
        lock.lock(); let w = where_; lock.unlock()
        setProfile(value, w, now: now)
    }

    /// Name ("DJ David") and position ("DJ Booth"), asked when entering the chat.
    public func setProfile(_ name: String, _ place: String, now: TimeInterval = Date().timeIntervalSince1970) {
        lock.lock()
        nick = SuiteChat.clean(name, max: SuiteChat.maxNick)
        where_ = SuiteChat.clean(place, max: SuiteChat.maxNick)
        if on { here(now) }
        lock.unlock()
        onChange?()
    }

    /// A message from this program; false while off, without a nickname or with an empty text.
    /// `urgent`: an EMERGENCY message; every other program shows it as a pop-up at once.
    @discardableResult
    public func post(_ value: String, urgent: Bool = false, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let t = SuiteChat.clean(value, max: SuiteChat.maxText)
        lock.lock()
        guard on, !t.isEmpty, !nick.isEmpty else { lock.unlock(); return false }
        seq += 1
        // A random part after the counter: nobody can take this program's next ids in advance (spec, abgleich S7).
        let line = Line(id: "\(peer)-\(seq)\(SuiteChat.newPeerId().prefix(8))", nick: nick, where_: where_, app: app, text: t, at: Date(timeIntervalSince1970: now),
                        mine: true, urgent: urgent)
        keep(line)
        let json = msgJSON(line, old: false)
        out?.send(json, delay: 0)
        out?.send(json, delay: 0.3) // a second copy: Wi-Fi loses single datagrams now and then
        lock.unlock()
        onChange?()
        return true
    }

    /// Twice a second: presence every 5 s, peers that went silent leave.
    public func tick(now: TimeInterval = Date().timeIntervalSince1970) {
        lock.lock()
        guard on else { lock.unlock(); return }
        if now - lastHere >= SuiteChat.hereEvery { here(now) }
        // Two newcomers within 10 s: the others' history lock left the second one without history; it asks once more.
        if !gotHistory, !askedAgain, now - joinedAt >= 12 {
            askedAgain = true
            historyUntil = now + 5
            out?.send(base("history?"), delay: 0)
        }
        let before = peers.count
        peers = peers.filter { now - $0.value.lastSeen <= SuiteChat.goneAfter }
        let changed = peers.count != before
        lock.unlock()
        if changed { onChange?() }
    }

    /// Quitting: the others see it at once.
    public func stop() {
        lock.lock()
        if on { out?.send(base("bye"), delay: 0) }
        lock.unlock()
    }

    public var snapshot: (on: Bool, nick: String, where_: String, members: [Member], lines: [Line]) {
        lock.lock(); defer { lock.unlock() }
        // A program that has not said who it is yet (only "history?" so far) is not listed.
        return (on, nick, where_, peers.values.filter { !$0.nick.isEmpty || !$0.app.isEmpty }
                    .map { Member(nick: $0.nick, where_: $0.where_, app: $0.app) }
                    .sorted { $0.nick < $1.nick },
                lines.sorted { $0.at < $1.at })
    }

    /// For a problem report: never a text, never a nickname.
    public var diagnostics: String {
        lock.lock(); defer { lock.unlock() }
        return "Suite chat: \(on ? "on" : "off"), \(peers.count) other programs, \(lines.count) messages in memory"
    }

    private func here(_ now: TimeInterval) {
        lastHere = now
        out?.send(json(["suite": "chat", "v": 1, "t": "here", "peer": peer, "nick": nick, "where": where_, "app": app]), delay: 0)
    }

    // MARK: the others

    /// A datagram from the network. Anything malformed, from this program itself or beyond the limits is dropped.
    public func receive(_ data: Data, now: TimeInterval = Date().timeIntervalSince1970) {
        guard data.count <= SuiteChat.maxDatagram,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["suite"] as? String == "chat", SuiteChat.number(o["v"]) == 1,
              let from = o["peer"] as? String, from != peer,
              from.range(of: #"\A[0-9a-z]{8,32}\z"#, options: .regularExpression) != nil,
              let type = o["t"] as? String else { return }
        lock.lock()
        guard on else { lock.unlock(); return }
        var changed = false
        if type == "msg", SuiteChat.isTrue(o["old"]) {
            // History never adds a peer nor keeps one in the room: it may come from someone who left long ago (spec).
            let known = peers[from]
            let limited = known == nil && now >= historyUntil
            if limited {
                strangerTimes.removeAll { now - $0 > SuiteChat.burstWindow }
                guard strangerTimes.count < SuiteChat.burst else { lock.unlock(); return }
            }
            changed = message(known, from, o, now)
            if limited && changed { strangerTimes.append(now) }
            lock.unlock()
            if changed { onChange?() }
            return
        }
        if type == "bye" {
            changed = peers.removeValue(forKey: from) != nil
        } else {
            let p: PeerState
            if let known = peers[from] {
                p = known
            } else if peers.count < SuiteChat.maxPeers {
                p = PeerState()
                peers[from] = p
                changed = true
            } else {
                lock.unlock(); return
            }
            p.lastSeen = now
            switch type {
            case "here":
                let n = SuiteChat.clean(o["nick"] as? String ?? "", max: SuiteChat.maxNick)
                let w = SuiteChat.clean(o["where"] as? String ?? "", max: SuiteChat.maxNick)
                let a = SuiteChat.clean(o["app"] as? String ?? "", max: SuiteChat.maxNick)
                if n != p.nick || w != p.where_ || a != p.app { p.nick = n; p.where_ = w; p.app = a; changed = true }
            case "msg":
                changed = message(p, from, o, now) || changed
            case "history?":
                // Once in 10 s, from anyone, and only with something to tell: a flood of questions cannot flood the net.
                guard !lines.isEmpty, now - lastHistoryAnswer >= SuiteChat.historyCooldown else { break }
                lastHistoryAnswer = now
                let sorted = lines // in the order they came, like LJ Link and VJ-Link
                for (k, l) in sorted[max(0, sorted.count - SuiteChat.historyAnswer)...].enumerated() {
                    out?.send(msgJSON(l, old: true), delay: 0.02 * Double(k + 1))
                }
            default:
                break // newer versions
            }
        }
        lock.unlock()
        if changed { onChange?() }
    }

    private func message(_ p: PeerState?, _ from: String, _ o: [String: Any], _ now: TimeInterval) -> Bool {
        // The id belongs to its sender ("peer-17"): nobody can pass off a message as another's (spec, QS 10 KANN 12).
        guard let id = o["id"] as? String, id.hasPrefix(from + "-"), id.unicodeScalars.count <= 64, !idSet.contains(id) else { return false }
        let t = SuiteChat.clean(o["text"] as? String ?? "", max: SuiteChat.maxText)
        guard !t.isEmpty else { return false }
        let old = SuiteChat.isTrue(o["old"])
        let expected = old && now < historyUntil
        if let p {
            p.times.removeAll { now - $0 > SuiteChat.burstWindow }
            if p.times.count >= SuiteChat.burst && !expected { return false }
            if !expected { p.times.append(now) }
            // A new message also tells who wrote it (a "here" may have been lost); history does not.
            if !old {
                if p.nick.isEmpty { p.nick = SuiteChat.clean(o["nick"] as? String ?? "", max: SuiteChat.maxNick) }
                if p.app.isEmpty { p.app = SuiteChat.clean(o["app"] as? String ?? "", max: SuiteChat.maxNick) }
                if p.where_.isEmpty { p.where_ = SuiteChat.clean(o["where"] as? String ?? "", max: SuiteChat.maxNick) }
            }
        }
        // Only a sane time: 1e300 made LJL Link crash when it sent the message on as history (QS 10, MUSS 1).
        let raw = SuiteChat.number(o["at"]) ?? -1
        // A live message is placed by its arrival (a sender's wrong clock must not hide it); history by its own time.
        let at = old && raw.isFinite && raw >= 0 && raw <= SuiteChat.maxAtMs ? Date(timeIntervalSince1970: raw / 1000) : Date(timeIntervalSince1970: now)
        // At most 3 pop-ups per peer in a minute; more come as normal messages (QS 10).
        var urgent = SuiteChat.isTrue(o["urgent"]) && !old
        if urgent, let p {
            p.urgentTimes.removeAll { now - $0 > SuiteChat.urgentWindow }
            if p.urgentTimes.count >= SuiteChat.urgentBurst { urgent = false } else { p.urgentTimes.append(now) }
        }
        keep(Line(id: id, nick: SuiteChat.clean(o["nick"] as? String ?? "", max: SuiteChat.maxNick),
                  where_: SuiteChat.clean(o["where"] as? String ?? "", max: SuiteChat.maxNick),
                  app: SuiteChat.clean(o["app"] as? String ?? "", max: SuiteChat.maxNick), text: t, at: at, mine: false,
                  urgent: urgent, old: old))
        if old { gotHistory = true }
        return true
    }

    private func keep(_ l: Line) {
        idSet.insert(l.id)
        ids.append(l.id)
        if ids.count > 4 * SuiteChat.maxKept { idSet.remove(ids.removeFirst()) }
        lines.append(l)
        if lines.count > SuiteChat.maxKept { lines.removeFirst(lines.count - SuiteChat.maxKept) }
    }

    // MARK: helpers

    /// Line breaks and tabs become spaces, direction marks and control characters go, trimmed, at most `max` code points.
    public static func clean(_ s: String, max: Int) -> String {
        var out = String.UnicodeScalarView()
        var lastWasBreak = false
        for u in s.unicodeScalars {
            switch u.value {
            // A run of line breaks and tabs becomes one space (as in LJ Link and VJ-Link).
            case 0x0A, 0x0D, 0x09, 0x2028, 0x2029: if out.last != " " || !lastWasBreak { out.append(" ") }; lastWasBreak = true; continue
            case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: continue
            default:
                if u.properties.generalCategory == .control { continue }
                out.append(u)
            }
            lastWasBreak = false
        }
        // Trimmed of Unicode white space at both ends (spec); runs inside are kept, as in LJ Link and VJ-Link.
        var t = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        if t.unicodeScalars.count > max {
            t = String(String.UnicodeScalarView(t.unicodeScalars.prefix(max))).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    private func base(_ type: String) -> String {
        json(["suite": "chat", "v": 1, "t": type, "peer": peer])
    }

    private func msgJSON(_ l: Line, old: Bool) -> String {
        var o: [String: Any] = ["suite": "chat", "v": 1, "t": "msg", "peer": String(l.id.prefix { $0 != "-" }), // the author's peer: everything before the first "-"
                                "id": l.id, "nick": l.nick, "where": l.where_, "app": l.app, "text": l.text,
                                "at": Int64(max(0, min(SuiteChat.maxAtMs, (l.at.timeIntervalSince1970 * 1000).rounded())))]
        if old { o["old"] = true }
        if l.urgent { o["urgent"] = true }
        return json(o)
    }

    private func json(_ o: [String: Any]) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Network

extension SuiteChat {
    /// UDP multicast on every IPv4 adapter that is up (BSD sockets); adapters are checked again every 30 s.
    public final class Net: Out {
        private let queue = DispatchQueue(label: "suite.chat.net")
        private let work = DispatchQueue(label: "suite.chat.work", qos: .utility)
        private var fd: Int32 = -1
        private var reader: DispatchSourceRead?
        private var timer: DispatchSourceTimer?
        private var joined: [String: in_addr] = [:]
        private weak var chat: SuiteChat?
        public private(set) var running = false
        private let port: UInt16

        /// `port`: the suite's port; tests use another one, so they never write into a real room.
        public init(port: UInt16 = SuiteChat.port) { self.port = port }

        /// Opens the socket; false if the port cannot be used (the chat then stays empty, the app runs on).
        @discardableResult
        public func start(_ chat: SuiteChat) -> Bool {
            queue.sync {
                self.chat = chat
                if running { return true }
                let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard s >= 0 else { return false }
                var yes: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr = in_addr(s_addr: INADDR_ANY)
                let ok = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                guard ok == 0 else { close(s); return false }
                var ttl: UInt8 = 1
                setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, 1)
                var loop: UInt8 = 1
                setsockopt(s, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, 1)
                fd = s
                running = true
                rejoin()
                let r = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
                r.setEventHandler { [weak self] in self?.read() }
                r.resume()
                reader = r
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now() + 0.5, repeating: 0.5)
                var count = 0
                t.setEventHandler { [weak self] in
                    count += 1
                    if count % 60 == 0 { self?.rejoin() }
                    let c = self?.chat
                    DispatchQueue.global().async { c?.tick() }
                }
                t.resume()
                timer = t
                return true
            }
        }

        private let pendingLock = NSLock()
        private var pending = 0
        private var inFlight = 0

        /// At most `maxPending` datagrams wait; more are dropped (QS 10: a flood must not fill the memory).
        public func send(_ json: String, delay: TimeInterval) {
            pendingLock.lock()
            // "bye" always goes out (quitting); everything else at most 64 waiting.
            guard pending < SuiteChat.maxPending || json.contains(#""t":"bye""#) else { pendingLock.unlock(); return }
            pending += 1
            pendingLock.unlock()
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.pendingLock.lock(); self.pending -= 1; self.pendingLock.unlock()
                self.sendNow(json)
            }
        }

        /// Waits until everything asked for so far is sent (quitting: the "bye" must go out first).
        public func drain(timeout: TimeInterval = 0.5) {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                pendingLock.lock(); let p = pending; pendingLock.unlock()
                if p == 0 { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            queue.sync {}
        }

        private func sendNow(_ json: String) {
            guard fd >= 0 else { return }
            var to = sockaddr_in()
            to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            to.sin_family = sa_family_t(AF_INET)
            to.sin_port = port.bigEndian
            to.sin_addr = in_addr(s_addr: inet_addr(SuiteChat.group))
            let bytes = Array(json.utf8)
            for (_, var a) in joined {
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &a, socklen_t(MemoryLayout<in_addr>.size))
                _ = withUnsafePointer(to: &to) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        private func read() {
            var buf = [UInt8](repeating: 0, count: SuiteChat.maxDatagram + 1)
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0, n <= SuiteChat.maxDatagram else { return }
            let data = Data(buf[0..<n])
            // One after the other on one queue, at most 256 waiting: a flood costs CPU on this queue only, never
            // the main thread or Serato (QS 10, SOLLTE 4).
            pendingLock.lock()
            guard inFlight < 256 else { pendingLock.unlock(); return }
            inFlight += 1
            pendingLock.unlock()
            let c = chat
            work.async { [weak self] in
                c?.receive(data)
                self?.pendingLock.lock(); self?.inFlight -= 1; self?.pendingLock.unlock()
            }
        }

        /// IPv4 adapters that are up, can multicast, not loopback and not self-assigned (169.254.x.x).
        private static func adapters() -> [String: in_addr] {
            var out: [String: in_addr] = [:]
            var list: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&list) == 0 else { return out }
            defer { freeifaddrs(list) }
            var p = list
            while let i = p {
                defer { p = i.pointee.ifa_next }
                let flags = Int32(i.pointee.ifa_flags)
                guard let sa = i.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                      flags & IFF_UP != 0, flags & IFF_MULTICAST != 0, flags & IFF_LOOPBACK == 0 else { continue }
                let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                if UInt32(bigEndian: a.s_addr) >> 16 == 0xA9FE { continue } // 169.254.x.x
                out[String(cString: i.pointee.ifa_name)] = a
            }
            return out
        }

        private func rejoin() {
            guard fd >= 0 else { return }
            let now = Net.adapters()
            for (name, a) in now where joined[name]?.s_addr != a.s_addr {
                var m = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr(SuiteChat.group)), imr_interface: a)
                if setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &m, socklen_t(MemoryLayout<ip_mreq>.size)) == 0
                    || errno == EADDRINUSE {
                    joined[name] = a
                }
            }
            for name in joined.keys where now[name] == nil { joined.removeValue(forKey: name) }
        }
    }
}

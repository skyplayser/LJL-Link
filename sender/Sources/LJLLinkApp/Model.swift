import AppKit
import Foundation
import SenderCore

/// German or English, after the Mac's first preferred language.
enum L {
    static let german = (Locale.preferredLanguages.first ?? "en").hasPrefix("de")
    static func t(_ de: String, _ en: String) -> String { german ? de : en }
}

/// Everything the window and the menu bar show. Lives on the main thread; the sender reports from its own queues.
@MainActor
final class Model: ObservableObject {
    static let shared = Model()
    static let version = "0.4.0"

    enum Phase: Equatable { case askNames, running }
    enum Link: Equatable { case connecting, connected, rejected, waiting, pending }

    @Published var phase: Phase = .askNames
    @Published var names = false
    @Published var link: Link = .connecting
    @Published var linkText = ""
    /// club.json from the club's stick: optional. Without it LJL Link finds LJ Link by Bonjour and the LJ allows it.
    @Published var club: ClubConfig?
    /// The LJ Link this Mac is connected to (its club name), for the header.
    @Published var boothName: String?
    @Published var decks: [Sender.DeckStatus] = []
    @Published var screen: Sender.ScreenState = .off
    @Published var seratoFound = true
    @Published var log: [String] = []
    @Published var clubError: String?
    @Published var showReport = false
    @Published var showHelp = false

    /// Suite chat (Alpha, LJ Link docs/suite-chat.md): one room with every suite program in the network, no host. On by
    /// default; the nickname lives only in memory (nothing is written to the DJ's Mac).
    let chatNet = SuiteChat.Net()
    lazy var room = SuiteChat(app: "LJL Link", out: chatNet)
    @Published var chatOn = true
    @Published var chatNick = ""
    @Published var chatWhere = ""
    @Published var chatMembers: [SuiteChat.Member] = []
    @Published var chatLines: [SuiteChat.Line] = []
    /// Unread messages: also a badge on the Dock icon (circle in the system's accent).
    @Published var chatUnread = 0 {
        didSet { NSApp?.dockTile.badgeLabel = chatUnread > 0 ? (chatUnread > 99 ? "99+" : "\(chatUnread)") : nil }
    }
    private var alerted = Set<String>()
    /// EMERGENCY messages beyond the 20 open pop-ups: shown as normal messages (spec).
    @Published var downgraded = Set<String>()
    @Published var chatNote: String?
    /// Ids of messages from others already counted (the list is bounded at 200, so a count stopped at 200; QS 10).
    private var othersSeen = Set<String>()
    private var chatRefreshPending = false

    private var sender: Sender?
    private var timer: Timer?

    private init() {
        // The club's stick: club.json next to the app (optional). During development also LJL_CLUB=<file>.
        if let path = ProcessInfo.processInfo.environment["LJL_CLUB"] { loadClub(URL(fileURLWithPath: path)) }
        if club == nil, let c = ClubConfig.load() { club = c }
        phase = .askNames
        startChat()
        // Development and tests: answer the question at start (LJL_NAMES=1 or 0).
        if phase == .askNames, let a = ProcessInfo.processInfo.environment["LJL_NAMES"] {
            DispatchQueue.main.async { Model.shared.start(names: a == "1") }
        }
    }

    /// The DJ picked a club.json by hand (stick without one next to the app).
    func loadClub(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(ClubConfig.self, from: data),
              !c.hosts.isEmpty, !c.key.isEmpty else {
            clubError = L.t("Diese Datei ist keine gültige club.json.", "This file is not a valid club.json.")
            return
        }
        clubError = nil
        club = c
        // Already sending: start again with the club's key.
        if let s = sender {
            s.stop()
            sender = nil
            timer?.invalidate()
            startSender()
        }
    }

    func chooseClub() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.allowsMultipleSelection = false
        p.message = L.t("club.json vom Club-Stick wählen", "Choose club.json from the club's stick")
        if p.runModal() == .OK, let url = p.url { loadClub(url) }
    }

    /// Answer to the question at start; starts sending.
    func start(names: Bool) {
        self.names = names
        phase = .running
        startSender()
    }

    private func startSender() {
        guard sender == nil else { return }
        guard let folder = SeratoLog.seratoFolder() else {
            // Serato never ran on this Mac (or another user): look again in a moment.
            seratoFound = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startSender() }
            return
        }
        seratoFound = true
        addLog(L.t("Start, Tracknamen \(names ? "an" : "aus")", "Start, track names \(names ? "on" : "off")"))
        let s = Sender(config: club, seratoFolder: folder, names: names,
                       computerName: Host.current().localizedName ?? "Mac", software: "Serato DJ Pro",
                       appVersion: Model.version,
                       onState: { st in Task { @MainActor in Model.shared.connection(st) } },
                       log: { line in Task { @MainActor in Model.shared.addLog(line) } })
        sender = s
        s.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in Model.shared.refresh() }
        }
    }

    private func refresh() {
        guard let sender else { return }
        let d = sender.status()
        if d != decks { decks = d }
        let sc = sender.screenStatus
        if sc != screen { screen = sc }
    }

    func setNames(_ on: Bool) {
        guard on != names else { return }
        names = on
        sender?.setNames(on)
        addLog(L.t("Tracknamen \(on ? "an" : "aus")", "Track names \(on ? "on" : "off")"))
    }

    private func connection(_ st: Connection.State) {
        switch st {
        case .connecting(let h):
            link = .connecting
            linkText = L.t("Suche LJ Link (\(h)) …", "Looking for LJ Link (\(h)) …")
        case .searching:
            link = .connecting
            linkText = L.t("Suche LJ Link im Netzwerk … Der Mac muss im selben Netzwerk sein wie der Rechner in der Booth.",
                           "Looking for LJ Link in the network … This Mac has to be in the same network as the booth computer.")
        case .pending(let n):
            link = .pending
            linkText = L.t("Gefunden: \(n). Warte auf Freigabe in der Booth – die Lichttechnik klickt dort einmal auf „Erlauben“, danach kennt LJ Link diesen Mac.",
                           "Found: \(n). Waiting for approval in the booth – the lighting tech clicks “Allow” there once; after that LJ Link knows this Mac.")
        case .connected(let c):
            link = .connected
            boothName = c
            linkText = L.t("Verbunden mit LJ Link – \(c)", "Connected to LJ Link – \(c)")
        case .rejected(let r):
            link = .rejected
            switch r {
            case "key": linkText = L.t("Der Club-Schlüssel auf diesem Stick gilt nicht mehr. Bitte den Stick in der Booth neu vorbereiten lassen.",
                                       "The club key on this stick is no longer valid. Please have the stick prepared again in the booth.")
            case "full": linkText = L.t("LJ Link hat schon 4 Sender verbunden. Neuer Versuch gleich …",
                                        "LJ Link already has 4 senders. Trying again shortly …")
            case "protocol": linkText = L.t("Diese App passt nicht zur LJ-Link-Version in der Booth.",
                                            "This app does not match the LJ Link version in the booth.")
            case "denied": linkText = L.t("In der Booth abgelehnt. Neuer Versuch in einer Minute – sprich am besten kurz mit der Lichttechnik.",
                                          "Refused in the booth. Trying again in a minute – best have a quick word with the lighting tech.")
            case "timeout": linkText = L.t("Keine Antwort aus der Booth. Neuer Versuch gleich …",
                                           "No answer from the booth. Trying again shortly …")
            case "old": linkText = L.t("LJ Link in der Booth kann LJL Link noch nicht ohne club.json annehmen. Bitte LJ Link aktualisieren – oder die club.json vom Club wählen.",
                                       "LJ Link in the booth cannot accept LJL Link without club.json yet. Please update LJ Link – or choose the club's club.json.")
            default: linkText = L.t("LJ Link hat abgelehnt (\(r)).", "LJ Link refused (\(r)).")
            }
        case .waiting:
            link = .waiting
            linkText = L.t("LJ Link nicht erreichbar – neuer Versuch …", "LJ Link not reachable – trying again …")
        }
    }

    // MARK: suite chat

    private func startChat() {
        // Many changes at once (a flood, or the history): one refresh every 0.15 s at most.
        room.onChange = {
            Task { @MainActor in
                let m = Model.shared
                guard !m.chatRefreshPending else { return }
                m.chatRefreshPending = true
                try? await Task.sleep(nanoseconds: 150_000_000)
                m.chatRefreshPending = false
                m.chatChanged()
            }
        }
        if chatNet.start(room) {
            room.setOn(true)
            // Development and tests only (environment, never on a club's stick): name, position and one message.
            let env = ProcessInfo.processInfo.environment
            if let n = env["LJL_CHAT_NICK"] { room.setProfile(n, env["LJL_CHAT_WHERE"] ?? "") }
            if let say = env["LJL_CHAT_SAY"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { Model.shared.sendChat(say, urgent: env["LJL_CHAT_SAY_URGENT"] == "1") }
            }
        } else {
            chatOn = false
            chatNote = L.t("Der Chat ließ sich nicht starten: Der Netzwerk-Port ist belegt.", "The chat could not start: the network port is in use.")
        }
    }

    func chatChanged() {
        let s = room.snapshot
        // Only live messages of others count as unread; history after joining does not (VJ-Link found it showing 9+).
        let fresh = s.lines.filter { !$0.mine && !$0.old && !othersSeen.contains($0.id) }
        if !fresh.isEmpty, !NSApp.isActive {
            chatUnread += fresh.count
            NSApp.requestUserAttention(.informationalRequest) // visible only: the Mac's sound may be the DJ mixer
        }
        othersSeen = Set(s.lines.filter { !$0.mine }.map(\.id))
        // EMERGENCY from someone else: the pop-up at the bottom right, once per message.
        for l in s.lines where l.urgent && !l.mine && !alerted.contains(l.id) {
            alerted.insert(l.id)
            if !EmergencyPanel.shared.show(l) { downgraded.insert(l.id) }
        }
        alerted.formIntersection(s.lines.map(\.id)) // bounded like the list
        if s.lines != chatLines { chatLines = s.lines }
        if s.where_ != chatWhere { chatWhere = s.where_ }
        if s.members != chatMembers { chatMembers = s.members }
        if s.nick != chatNick { chatNick = s.nick }
    }

    func setChatOn(_ on: Bool) {
        guard on != chatOn else { return }
        if on, !chatNet.running, !chatNet.start(room) {
            chatNote = L.t("Der Chat ließ sich nicht starten: Der Netzwerk-Port ist belegt.", "The chat could not start: the network port is in use.")
            return
        }
        chatOn = on
        chatNote = nil
        room.setOn(on)
        if !on { chatMembers = []; EmergencyPanel.shared.closeAll() }
        addLog(on ? L.t("Chat eingeschaltet", "Chat switched on") : L.t("Chat ausgeschaltet", "Chat switched off"))
    }

    func setChatProfile(_ nick: String, _ place: String) {
        room.setProfile(nick, place)
    }

    @discardableResult
    func sendChat(_ text: String, urgent: Bool = false) -> Bool {
        let ok = room.post(text, urgent: urgent)
        chatNote = ok ? nil : L.t("Nicht gesendet.", "Not sent.")
        return ok
    }

    func addLog(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(line)")
        // Development: the same lines on standard output (started from a terminal with LJL_DEBUG_POSITIONS=1).
        if Sender.debugPositions { print("\(f.string(from: Date())) \(line)"); fflush(stdout) }
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    func allowScreen() {
        if !ScreenTimeReader.requestPermission(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Says goodbye to LJ Link (its decks disappear at once) before the app ends.
    func stop() {
        timer?.invalidate()
        room.stop()
        chatNet.drain() // the "bye" must go out before the app ends
        sender?.stop()
        sender = nil
    }
}

import AVFoundation
import Foundation

/// Ties Serato's log, the waveform builder and the connection together: every deck load becomes a `load` message,
/// followed by the overview and detail waveform as soon as they are built. Keeps the current state of each deck so a
/// reconnect can send it again.
public final class Sender: @unchecked Sendable {  // shared state behind `lock`
    struct DeckState {
        var load: DeckLoad
        var id: String
        var tags: TrackTags
        var waveforms: Waveforms?
        var positionMs: Int64?
        var playing = false
        var positionAt: Date?
        var speed: Double?
    }

    /// What the app window shows per deck. Title and artist stay on this Mac unless track names are on.
    public struct DeckStatus: Identifiable, Equatable {
        public var id: Int { deck }
        public let deck: Int
        public let title: String
        public let artist: String?
        public let lengthMs: Int64
        public let bpm: Double?
        public let key: String?
        public let waveform: Bool
        /// Last position read from Serato's display, and when; nil while Serato does not show this deck's time.
        public let positionMs: Int64?
        public let playing: Bool
        public let positionAt: Date?
    }

    /// Reading Serato's time display.
    public enum ScreenState: Equatable {
        case off
        case waiting(String)
        case reading
        /// macOS does not allow screen recording for this app.
        case denied
    }

    private let follower: SeratoLogFollower
    private var connection: Connection!
    private let work = DispatchQueue(label: "ljlink.sender.waveforms", qos: .utility)  // never compete with Serato
    private let lock = NSLock()
    private var decks: [Int: DeckState] = [:]
    private var names: Bool
    private var pollTimer: DispatchSourceTimer?
    private var screen: ScreenTimeReader?
    private let readPositions: Bool
    public let log: (String) -> Void
    private var screenState = ScreenState.off
    private var stopped = false

    public init(config: ClubConfig, seratoFolder: URL, names: Bool, computerName: String, software: String,
                appVersion: String, readPositions: Bool = true,
                onState: @escaping (Connection.State) -> Void, log: @escaping (String) -> Void) {
        follower = SeratoLogFollower(seratoFolder: seratoFolder)
        self.names = names
        self.readPositions = readPositions
        self.log = log
        connection = Connection(
            config: config,
            hello: { [unowned self] in
                .hello(key: config.key, name: computerName, software: software, app: appVersion, names: self.namesOn) },
            resend: { [unowned self] in self.currentState() },
            onState: onState)
        connection.moreHosts = { [finder] in finder.booths }
    }

    /// LJ Links in the network (Bonjour), tried after the addresses in club.json.
    private let finder = BoothFinder()

    var namesOn: Bool { lock.lock(); defer { lock.unlock() }; return names }

    public func start() {
        finder.start()
        connection.start()
        for l in follower.current() { loaded(l) }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            for l in self.follower.poll() { self.loaded(l) }
        }
        t.resume()
        pollTimer = t
        if readPositions { startScreen() }
    }

    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
        pollTimer?.cancel()
        screen?.stop()
        connection.stop()
        finder.stop()
    }

    /// Reads the playhead of every deck from Serato's time display (concept 5.3a) and sends it as `position`.
    private func startScreen() {
        let reader = ScreenTimeReader(
            decks: { [weak self] in self?.deckInfos() ?? [] },
            onPosition: { [weak self] deck, ms, playing, speed in
                guard let self else { return }
                self.lock.lock(); let id = self.decks[deck]?.id; self.lock.unlock()
                guard let id else { return }
                self.lock.lock()
                if self.decks[deck]?.id == id {
                    self.decks[deck]?.positionMs = ms; self.decks[deck]?.playing = playing; self.decks[deck]?.speed = speed
                    self.decks[deck]?.positionAt = ms == nil ? nil : Date()
                }
                self.lock.unlock()
                if Sender.debugPositions { self.log("pos;\(deck);\(ms.map(String.init) ?? "none");\(playing ? 1 : 0);\(speed.map { String(format: "%.4f", $0) } ?? "-")") }
                self.connection.send(.position(deck: deck, id: id, ms: ms, playing: playing, speed: speed, source: "screen"))
            },
            log: log)
        screen = reader
        reader.onStop = { [weak self] in
            // Serato quit or the window went away: look for it again.
            self?.setScreen(.waiting("Serato-Fenster weg"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { self?.startCapture(reader) }
        }
        startCapture(reader)
    }

    /// Starts reading Serato's window; retried every 3 s while Serato is not open or the permission is missing.
    private func startCapture(_ reader: ScreenTimeReader) {
        lock.lock(); let isStopped = stopped; lock.unlock()
        if isStopped { return }
        Task {
            do {
                try await reader.start()
                self.setScreen(.reading)
            } catch {
                let denied = ScreenTimeReader.isPermissionError(error)
                let state: ScreenState = denied ? .denied : .waiting(error.localizedDescription)
                if self.screenStatus != state { self.log("Bildschirm: \(error.localizedDescription) – ohne Position, neuer Versuch") }
                self.setScreen(state)
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { self.startCapture(reader) }
            }
        }
    }

    private func setScreen(_ s: ScreenState) { lock.lock(); screenState = s; lock.unlock() }

    /// For the app window.
    public var screenStatus: ScreenState { lock.lock(); defer { lock.unlock() }; return screenState }

    /// For the app window: every deck with a track, sorted.
    public func status() -> [DeckStatus] {
        lock.lock(); defer { lock.unlock() }
        return decks.keys.sorted().compactMap { d in
            decks[d].map { s in
                // The reader reports "no position" itself after 6 s without a readable field (reportLost).
                let fresh = s.positionMs != nil
                return DeckStatus(deck: d, title: s.tags.title ?? s.load.file.deletingPathExtension().lastPathComponent,
                                  artist: s.tags.artist, lengthMs: s.load.lengthMs, bpm: s.tags.bpm, key: s.tags.key,
                                  waveform: s.waveforms != nil, positionMs: fresh ? s.positionMs : nil,
                                  playing: fresh && s.playing, positionAt: s.positionAt)
            }
        }
    }

    /// Development: log every sent position (LJL_DEBUG_POSITIONS=1).
    public static let debugPositions = ProcessInfo.processInfo.environment["LJL_DEBUG_POSITIONS"] == "1"

    func deckInfos() -> [DeckInfo] {
        lock.lock(); defer { lock.unlock() }
        return decks.keys.sorted().compactMap { d in
            decks[d].map { DeckInfo(deck: d, lengthMs: $0.load.lengthMs, title: $0.tags.title) }
        }
    }

    /// The DJ switched track titles on or off.
    public func setNames(_ on: Bool) {
        lock.lock()
        names = on
        let current = decks
        lock.unlock()
        connection.send(.names(on: on))
        // With titles on again, send them for the tracks already on the decks.
        if on { for s in current.values { connection.send(loadMessage(s, names: true)) } }
    }

    private func loaded(_ l: DeckLoad) {
        let id = newTrackId()
        // BPM and key are sent always; title and artist only while the DJ allows track titles (loadMessage).
        let state = DeckState(load: l, id: id, tags: TrackTags.read(l.file), waveforms: nil)
        lock.lock(); decks[l.deck] = state; lock.unlock()
        log("Deck \(l.deck): \(namesOn ? l.file.lastPathComponent : "Track") geladen, \(l.lengthMs / 1000) s")
        connection.send(loadMessage(state, names: namesOn))
        work.async { [weak self] in
            guard let self else { return }
            let t0 = Date()
            do {
                let w = try WaveformBuilder.build(from: l.file)
                self.lock.lock()
                let current = self.decks[l.deck]?.id == id
                if current { self.decks[l.deck]?.waveforms = w }
                self.lock.unlock()
                guard current else { return }  // a newer track was loaded meanwhile
                self.log("Deck \(l.deck): Waveforms fertig in \(Int(Date().timeIntervalSince(t0) * 1000)) ms"
                         + (w.detail.count > Sender.maxDetailBytes ? " (Track über 40 min: nur Übersicht, Detail zu groß)" : ""))
                for m in Sender.waveformMessages(deck: l.deck, id: id, w) { self.connection.send(m) }
            } catch {
                self.log("Deck \(l.deck): keine Waveform (\((error as? WaveformError)?.kind ?? "\(type(of: error))"))")
            }
        }
    }

    private func loadMessage(_ s: DeckState, names: Bool) -> Message {
        .load(deck: s.load.deck, id: s.id, lengthMs: s.load.lengthMs, bpm: s.tags.bpm, key: s.tags.key,
              title: names ? s.tags.title : nil, artist: names ? s.tags.artist : nil)
    }

    /// LJ Link closes the connection on a message over 2 MB (protocol.md). Base64 makes 4 bytes of 3, so the detail
    /// waveform fits up to about 1.45 MB of raw data, i.e. tracks of about 40 minutes. Longer tracks (DJ mixes) get
    /// the overview only until the protocol can send the detail in pieces; otherwise the sender would be thrown out,
    /// reconnect, send again and loop.
    public static let maxDetailBytes = 1_450_000

    public static func waveformMessages(deck: Int, id: String, _ w: Waveforms) -> [Message] {
        var out: [Message] = [.waveform(deck: deck, id: id, kind: "overview", entries: w.overview.count / 4, data: w.overview)]
        if w.detail.count <= maxDetailBytes {
            out.append(.waveform(deck: deck, id: id, kind: "detail", entries: w.detailFrames, data: w.detail))
        }
        return out
    }

    /// Everything LJ Link needs after a (re)connect.
    func currentState() -> [Message] {
        lock.lock(); let current = decks; let n = names; lock.unlock()
        var out: [Message] = []
        for s in current.keys.sorted().compactMap({ current[$0] }) {
            out.append(loadMessage(s, names: n))
            if let w = s.waveforms { out += Sender.waveformMessages(deck: s.load.deck, id: s.id, w) }
            // The last position too: a paused deck sends none until it moves (found: after LJ Link restarted, paused
            // decks had no playhead). A playing one is carried on to now.
            if let p = s.positionMs {
                let run = s.playing ? Int64(Date().timeIntervalSince(s.positionAt ?? Date()) * 1000 * (s.speed ?? 1)) : 0
                out.append(.position(deck: s.load.deck, id: s.id, ms: min(s.load.lengthMs, p + run), playing: s.playing,
                                     speed: s.speed, source: "screen"))
            }
        }
        return out
    }
}

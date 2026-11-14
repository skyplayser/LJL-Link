import AppKit
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit
import Vision

/// Reads the deck times from Serato's window (concept 5.3a, way E): captures only that window, finds the time fields
/// once ("calibration", in overlapping tiles of the deck area), assigns them to decks (TimeFields.bind) and then reads
/// only those small crops on every new frame. Nothing of the picture leaves this class; out go deck positions.
@available(macOS 14.0, *)
public final class ScreenTimeReader: NSObject, SCStreamOutput, SCStreamDelegate {
    public typealias DecksProvider = () -> [DeckInfo]
    /// deck, position in ms, playing
    /// deck, position in ms (nil: Serato does not show this deck's time any more), playing, measured speed (pitch).
    public typealias PositionSink = (Int, Int64?, Bool, Double?) -> Void

    private let decks: DecksProvider
    private let onPosition: PositionSink
    private let log: (String) -> Void
    private let frames = DispatchQueue(label: "ljlink.screen.frames", qos: .utility)
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private var stream: SCStream?
    private var busy = false

    /// A time field assigned to a deck. Kept across calibrations as long as it reads well.
    struct Bound {
        var deck: Int
        var kind: Binding.Kind
        var rect: CGRect
        var misses = 0
        /// Learns this field's digits from Vision and then reads them alone (DigitReader).
        let reader = DigitReader()
        /// Thumbnail of the last crop and what it said: an unchanged crop is not read again.
        var lastThumb: [UInt8] = []
        var lastText: String?
        /// Own readings so far, and how often in a row the check against Vision disagreed.
        var ownReads = 0
        var disagree = 0
    }

    /// One captured frame. Only the parts that are needed become bitmaps (a whole 2582×1298 frame costs far more than
    /// a few small crops). Must be used inside the frame callback: the pixel buffer is reused afterwards.
    final class Frame {
        let image: CIImage
        let size: CGSize
        let ci: CIContext
        init(_ image: CIImage, ci: CIContext) { self.image = image; self.ci = ci; size = image.extent.size }
        lazy var full: CGImage? = ci.createCGImage(image, from: image.extent)
        /// Crop in top-left pixel coordinates.
        func crop(_ r: CGRect) -> CGImage? {
            let rr = r.intersection(CGRect(origin: .zero, size: size)).integral
            guard rr.width >= 2, rr.height >= 2 else { return nil }
            let e = image.extent
            return ci.createCGImage(image, from: CGRect(x: e.minX + rr.minX, y: e.maxY - rr.maxY, width: rr.width, height: rr.height))
        }
    }

    /// Counters for the development log (LJL_DEBUG_POSITIONS): how often Vision was still needed.
    private var stats = (frames: 0, skipped: 0, digits: 0, vision: 0, since: Date())
    private var bound: [Bound] = []
    private var trackers: [Int: PositionTracker] = [:]
    private var lastSent: [Int: Date] = [:]
    private var frameSize = CGSize.zero
    private var nextCalibration = Date.distantPast
    private var attempts = 0
    private var calibrating = false
    private let calibration = DispatchQueue(label: "ljlink.screen.calibration", qos: .utility)
    private var lastDeckSet: [DeckInfo] = []
    private var lastFound: [TimeField] = []
    private var pointScale: CGFloat = 1
    private var toolbarRef: [UInt8]?
    private var toolbarChanged = 0
    /// Serato's toolbar changed (another layout or deck count, or only the mouse over it): the places are checked by a
    /// calibration while reading goes on; until then no jump is accepted.
    private var suspect = false
    /// The toolbar of the previous frame, and since when it has not changed: an open layout menu or a layout being
    /// drawn keeps changing it. A check calibrates only after 1 s of quiet, else it saw the old layout.
    private var toolbarPrev: [UInt8]?
    private var toolbarQuietSince = Date.distantPast
    /// Decks LJ Link has a position for, and since when each has had no readable place.
    private var announced = Set<Int>()
    private var lostSince: [Int: Date] = [:]
    private var reads = 0
    private var pairBad: [Int: Int] = [:]
    /// Where each deck was seen in the current layout (tie-break for equal lengths, TimeFields.bind `previous`).
    private var seenAt: [(rect: CGRect, deck: Int)] = []
    /// After a new track on a deck, the display and the log do not change at the same instant: no pair check for 3 s.
    private var loadGrace: [Int: Date] = [:]
    /// Development: save the frames used for calibration (LJL_DEBUG_DIR=<folder>).
    private let debugDir = ProcessInfo.processInfo.environment["LJL_DEBUG_DIR"]

    public init(decks: @escaping DecksProvider, onPosition: @escaping PositionSink, log: @escaping (String) -> Void) {
        self.decks = decks
        self.onPosition = onPosition
        self.log = log
    }

    /// Starts capturing the largest window of Serato DJ Pro (development path; the app will use the system window picker).
    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ws = content.windows.filter { $0.owningApplication?.applicationName == "Serato DJ Pro" }
        guard let w = ws.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw NSError(domain: "ljlink", code: 1, userInfo: [NSLocalizedDescriptionKey: "kein Serato-Fenster gefunden"])
        }
        try await start(filter: SCContentFilter(desktopIndependentWindow: w), size: w.frame.size)
    }

    public func start(filter: SCContentFilter, size: CGSize) async throws {
        let cfg = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        frames.sync { pointScale = scale }   // read on the frames queue
        cfg.width = Int(size.width * scale)
        cfg.height = Int(size.height * scale)
        // 5 frames per second: Pro DJ Link players report their position about as often; LJ Link runs the playhead
        // on between two reports. 10 per second doubled the work for no visible gain.
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.queueDepth = 3
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames)
        try await s.startCapture()
        streamLock.withLock { stream = s }
        log("Bildschirm: Serato-Fenster wird gelesen (\(Int(size.width))×\(Int(size.height)), Faktor \(scale))")
    }

    public func stop() {
        streamLock.lock(); stopped = true; let s = stream; streamLock.unlock()
        s?.stopCapture { _ in }
    }

    /// Called when the capture ends by itself (Serato quit, its window closed).
    public var onStop: (() -> Void)?
    private var stopped = false
    /// `stream` and `stopped` are touched from the caller (start/stop) and from ScreenCaptureKit's delegate queue.
    private let streamLock = NSLock()

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("Bildschirm: Aufnahme beendet (\(error.localizedDescription))")
        streamLock.lock(); self.stream = nil; let wasStopped = stopped; streamLock.unlock()
        if !wasStopped { onStop?() }
    }

    /// macOS has not allowed screen recording for this app (yet).
    public static func isPermissionError(_ error: Error) -> Bool {
        let e = error as NSError
        return !CGPreflightScreenCaptureAccess() || (e.domain == SCStreamErrorDomain && e.code == SCStreamError.userDeclined.rawValue)
    }

    /// Shows macOS's question for screen recording (once; afterwards only System Settings can allow it).
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !busy else { return }
        if let infos = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = infos.first?[.status] as? Int, SCFrameStatus(rawValue: raw) != .complete { return }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        busy = true
        defer { busy = false }
        handle(Frame(CIImage(cvPixelBuffer: pb), ci: ci))
    }

    // MARK: per frame (on the frames queue)

    func handle(_ frame: Frame) {
        let size = frame.size
        // In the 2-deck view only decks 1 and 2 are on screen: decks 3/4 are neither searched nor assigned.
        let current = deckCount(frame) == 2 ? decks().filter { $0.deck <= 2 } : decks()
        let boundDecks = Set(bound.map(\.deck))
        if current.map({ "\($0.deck):\($0.lengthMs)" }) != lastDeckSet.map({ "\($0.deck):\($0.lengthMs)" }) {
            // A new track: its tracker starts over; an unbound deck may be bindable now.
            for d in current where !lastDeckSet.contains(d) {
                trackers[d.deck] = nil
                pairBad[d.deck] = 0
                loadGrace[d.deck] = Date().addingTimeInterval(3)
            }
            if !Set(current.map(\.deck)).subtracting(boundDecks).isEmpty { nextCalibration = .distantPast; attempts = 0 }
            lastDeckSet = current
        }
        if size != frameSize {
            // Other window size or screen: all places are new.
            dropAll(size)
        } else if layoutChanged(frame) {
            // Maybe another layout or deck count: old places may now show another deck's time. Often it is only the
            // mouse over the toolbar, so the places are checked instead of dropped (dropping cost 3 s of positions).
            suspect = true
            nextCalibration = .distantPast
            attempts = 0
        }
        // Calibrate a suspected change only on a settled toolbar: the change is first seen when the DJ opens the layout
        // menu; a calibration then still saw the old layout, "confirmed" it, and only the next one found the new places
        // (7-10 s without positions).
        let settled = Date().timeIntervalSince(toolbarQuietSince) >= 1.0
        if bound.contains(where: { $0.misses > 10 }) { nextCalibration = min(nextCalibration, Date()) }
        let missing = !Set(current.map(\.deck)).subtracting(Set(bound.filter { $0.misses <= 10 }.map(\.deck))).isEmpty
        // Calibration runs beside the reading (2-4 s of Vision work), so the playheads keep running meanwhile.
        if !calibrating && (missing || suspect) && (!suspect || settled) && Date() >= nextCalibration, let cg = frame.full {
            calibrating = true
            let previous = lastFound
            let seen = seenAt
            calibration.async { [weak self] in
                guard let self else { return }
                let t0 = Date()
                if let dir = self.debugDir { ScreenTimeReader.save(cg, to: "\(dir)/calib-\(Int(t0.timeIntervalSince1970 * 10)).png") }
                var (found, texts) = ScreenTimeReader.findFields(cg)
                // Fields of the last calibration that this frame missed (e.g. the platter needle crossed the digits)
                // are read again in this frame, so stacked pairs stay complete.
                for old in previous where !found.contains(where: { ScreenTimeReader.same($0.rect, old.rect) }) {
                    if let t = ScreenTimeReader.readText(cg, old.rect), let v = TimeFields.parse(t) {
                        found.append(TimeField(rect: old.rect, seconds: v.seconds, minus: v.minus))
                    }
                }
                let binds = TimeFields.bind(fields: found, texts: texts, decks: current, previous: seen, width: size.width)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                self.frames.async { self.lastFound = found; self.merge(binds.map { Bound(deck: $0.deck, kind: $0.kind, rect: found[$0.field].rect) },
                                               fields: found.count, decks: current, size: size, ms: ms, at: t0) }
            }
        }
        if !bound.isEmpty { read(frame, decks: current) }
        reportLost(current)
        logStats()
    }

    /// A deck whose time is not readable for 6 s (hidden by the layout, e.g. decks 3/4 in the 2-deck view; windows on
    /// top of Serato do not hide it, the capture sees Serato's window itself) gets "no position", so LJ Link does not run its playhead on blindly. 6 s: longer than a
    /// calibration after a layout change, during which LJ Link keeps running the playhead on.
    func reportLost(_ current: [DeckInfo]) {
        let live = Set(bound.filter { $0.misses <= 10 }.map(\.deck))
        let now = Date()
        for d in announced {
            if live.contains(d) && current.contains(where: { $0.deck == d }) { lostSince[d] = nil; continue }
            let since = lostSince[d] ?? now
            lostSince[d] = since
            if now.timeIntervalSince(since) >= 6 {
                announced.remove(d)
                lostSince[d] = nil
                // A deck that was at its end stays there (its fields may be unreadable then: the elapsed time runs past
                // the length and the remaining time is "--:--.-"); only otherwise the position is unknown.
                let info = current.first(where: { $0.deck == d })
                let atEnd = info.flatMap { i in trackers[d]?.positionMs.map { $0 >= i.lengthMs - 200 } } ?? false
                trackers[d] = nil   // the next reading is sent at once
                if atEnd, let i = info { onPosition(d, i.lengthMs, false, nil) } else { onPosition(d, nil, false, nil) }
            }
        }
    }

    func logStats() {
        stats.frames += 1
        guard ProcessInfo.processInfo.environment["LJL_DEBUG_POSITIONS"] == "1", Date().timeIntervalSince(stats.since) >= 15 else { return }
        log("Bildschirm-Statistik: \(stats.frames) Bilder, Felder unverändert \(stats.skipped), eigene Ziffern \(stats.digits), Vision \(stats.vision)")
        stats = (0, 0, 0, 0, Date())
    }

    func dropAll(_ size: CGSize) {
        bound.removeAll()
        lastFound.removeAll()
        pairBad.removeAll()
        seenAt.removeAll()
        frameSize = size
        nextCalibration = .distantPast
        attempts = 0
        toolbarRef = nil
        suspect = false
    }

    /// Serato's toolbar top left holds the layout menu and the 2/4 deck buttons. It only changes when the DJ switches
    /// the layout or deck count (or hovers there). A change that lasts 3 frames counts.
    func layoutChanged(_ frame: Frame) -> Bool {
        let r = CGRect(x: 0, y: 0, width: min(frame.size.width, 260 * pointScale), height: min(frame.size.height, 70 * pointScale)).integral
        guard let crop = frame.crop(r) else { return false }
        // Full resolution: the layout name is a few letters; in a thumbnail its change vanishes. Measured on Serato 5.0
        // captures: same layout 0.0 % changed pixels, another layout or deck count at least 0.9 %.
        let w = Int(r.width), h = Int(r.height)
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool {
            var n = 0
            for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 40 { n += 1 }
            return n * 1000 > a.count * 4
        }
        if let prev = toolbarPrev, prev.count == px.count, !differs(prev, px) {} else { toolbarQuietSince = Date() }
        toolbarPrev = px
        guard let ref = toolbarRef, ref.count == px.count else { toolbarRef = px; return false }
        var changedPx = 0
        for i in 0..<px.count where abs(Int(px[i]) - Int(ref[i])) > 40 { changedPx += 1 }
        if changedPx * 1000 > px.count * 4 {
            toolbarChanged += 1
            if toolbarChanged >= 2 { toolbarChanged = 0; toolbarRef = px; return true }
        } else {
            toolbarChanged = 0
        }
        return false
    }

    /// Serato's toolbar has the buttons "2" and "4" for the deck count; the active one is blue (measured: blue
    /// 179-187 against grey 33-43). nil if neither looks active (another skin or a covered toolbar).
    func deckCount(_ frame: Frame) -> Int? {
        func blue(_ x: CGFloat, _ y: CGFloat) -> Bool {
            let r = CGRect(x: (x - 4) * pointScale, y: (y - 3) * pointScale, width: 9 * pointScale, height: 7 * pointScale).integral
            guard let c = frame.crop(r) else { return false }
            var px = [UInt8](repeating: 0, count: 4)
            guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(c, in: CGRect(x: 0, y: 0, width: 1, height: 1))   // average colour
            return px[2] > 150 && Int(px[2]) - Int(px[0]) > 60
        }
        let two = blue(41, 49), four = blue(65, 49)
        return two == four ? nil : (two ? 2 : 4)
    }

    /// New assignments complete the old ones: a deck that still reads well keeps its fields.
    func merge(_ fresh: [Bound], fields: Int, decks: [DeckInfo], size: CGSize, ms: Int, at shot: Date) {
        calibrating = false
        guard size == frameSize else { return }  // the window changed meanwhile; the next calibration follows
        if suspect {
            // Check after a toolbar change: a place stays if the calibration put the same deck there, or if the time
            // found there (in the calibration frame) is where this deck should be by now, within 1.5 s. Only "a time
            // is there" kept places that showed another deck after a real layout change (decks stood still).
            suspect = false
            let found = lastFound
            let kept = bound.filter { b in
                if fresh.contains(where: { $0.deck == b.deck && ScreenTimeReader.same($0.rect, b.rect) }) { return true }
                if fresh.contains(where: { ScreenTimeReader.same($0.rect, b.rect) }) { return false }
                guard let f = found.first(where: { ScreenTimeReader.same($0.rect, b.rect) }),
                      let info = decks.first(where: { $0.deck == b.deck }),
                      let exp = trackers[b.deck]?.expected(at: shot) else { return false }
                let shown = b.kind == .elapsed ? (f.minus ? -f.seconds : f.seconds) : Double(info.lengthMs) / 1000 - f.seconds
                return abs(shown * 1000 - Double(exp)) < 1500
            }
            if kept.count != bound.count {
                log("Bildschirm: Layout geändert, Zeitfelder neu zugeordnet")
                seenAt.removeAll()
                pairBad.removeAll()
            }
            bound = kept
        }
        let healthy = Set(bound.filter { $0.misses <= 10 }.map(\.deck))
        bound.removeAll { !healthy.contains($0.deck) }
        // All fresh fields of every deck that has none left (both fields of a platter: one deck, two places).
        let have = Set(bound.map(\.deck))
        for f in fresh where !have.contains(f.deck) { bound.append(f) }
        for b in bound {
            seenAt.removeAll { ScreenTimeReader.same($0.rect, b.rect) }
            seenAt.append((b.rect, b.deck))
        }
        let unbound = Set(decks.map(\.deck)).subtracting(bound.map(\.deck)).sorted()
        // Missing decks: two quick retries after 1 s (the platter needle may hide digits), then growing pauses
        // 5, 10, 20, 40, 60 s (decks hidden by the layout, e.g. 3/4 in the 2-deck view).
        nextCalibration = Date().addingTimeInterval(unbound.isEmpty ? 3600 : (attempts < 2 ? 1 : min(60, 5 * pow(2, Double(attempts - 2)))))
        attempts += 1
        let summary = bound.sorted { ($0.deck, $0.kind.rawValue) < ($1.deck, $1.kind.rawValue) }
            .map { "Deck \($0.deck) \($0.kind == .elapsed ? "Laufzeit" : "Restzeit")" }.joined(separator: ", ")
        log("Bildschirm: \(fields) Zeitfelder, zugeordnet: \(summary.isEmpty ? "keine" : summary)"
            + (unbound.isEmpty ? "" : "; ohne Zuordnung: Deck \(unbound.map(String.init).joined(separator: ", "))")
            + " (\(ms) ms)")
    }

    func read(_ frame: Frame, decks: [DeckInfo]) {
        // One field per deck: elapsed if it reads well, else remaining.
        var chosen: [Int: Int] = [:]   // deck -> index into bound
        for (i, b) in bound.enumerated() {
            if let c = chosen[b.deck] {
                let cur = bound[c]
                let better = (b.misses < cur.misses) || (b.misses == cur.misses && b.kind == .elapsed)
                if better { chosen[b.deck] = i }
            } else {
                chosen[b.deck] = i
            }
        }
        reads += 1
        // Every 20th frame also the partner field of each deck that has both: elapsed + remaining must give the length.
        var partners: [Int: Int] = [:]   // deck -> index of the other field
        if reads % 20 == 0 {
            for (d, c) in chosen { if let o = bound.indices.first(where: { $0 != c && bound[$0].deck == d }) { partners[d] = o } }
        }
        let idx = Array(chosen.values) + Array(partners.values)
        var texts = [String?](repeating: nil, count: idx.count)
        // 1. Unchanged crop: same text as last time (a paused deck costs almost nothing).
        // 2. The field's own digit reader. 3. Vision for the rest (in parallel), and the digit reader learns from it.
        var needVision: [(k: Int, crop: CGImage)] = []
        let frameRect = CGRect(origin: .zero, size: frame.size)
        for (k, i) in idx.enumerated() {
            let r = bound[i].rect
            // One crop for both readers, with room around the field (the calibrated box may cut a digit off).
            let padR = r.insetBy(dx: -r.height * 0.6, dy: -r.height * 0.25).intersection(frameRect).integral
            guard let crop = frame.crop(padR) else { continue }
            let thumb = ScreenTimeReader.thumbnail(crop)
            // A jump waiting for confirmation is checked by Vision: the own reader could repeat its own misreading.
            let verify = trackers[bound[i].deck]?.hasPendingJump == true
            if !verify && !thumb.isEmpty && thumb == bound[i].lastThumb, let t = bound[i].lastText {
                texts[k] = t; stats.skipped += 1; continue
            }
            bound[i].lastThumb = thumb
            if !verify, let s = bound[i].reader.read(crop) {
                texts[k] = s; bound[i].lastText = s; stats.digits += 1
                bound[i].ownReads += 1
                // Every 20th own reading is checked by Vision (below); otherwise done.
                if bound[i].ownReads % 20 != 0 { continue }
            }
            needVision.append((k, crop))
        }
        if !needVision.isEmpty {
            let lock = NSLock()
            let heights = needVision.map { bound[idx[$0.k]].rect.height }
            var got = [(text: String, line: ClosedRange<Int>)?](repeating: nil, count: needVision.count)
            DispatchQueue.concurrentPerform(iterations: needVision.count) { j in
                let t = ScreenTimeReader.readCropWithBoxes(needVision[j].crop, textHeight: heights[j])
                lock.lock(); got[j] = t; lock.unlock()
            }
            stats.vision += needVision.count
            for (j, v) in needVision.enumerated() {
                let i = idx[v.k]
                if let own = texts[v.k], let vis = got[j]?.text, TimeFields.parse(vis) != nil {
                    // Check of an own reading: two disagreements in a row → relearn this field from scratch.
                    if own == vis.filter({ !$0.isWhitespace }) { bound[i].disagree = 0 } else {
                        bound[i].disagree += 1
                        if bound[i].disagree >= 2 { bound[i].reader.reset(); bound[i].disagree = 0; log("Bildschirm: Ziffern von Deck \(bound[i].deck) neu lernen") }
                    }
                }
                texts[v.k] = got[j]?.text ?? texts[v.k]
                bound[i].lastText = texts[v.k]
                if let g = got[j], TimeFields.parse(g.text) != nil { bound[i].reader.learn(v.crop, text: g.text, line: g.line) }
            }
        }
        let now = Date()
        var drop = Set<Int>()
        for (d, o) in partners where Date() >= (loadGrace[d] ?? .distantPast) {
            guard let c = chosen[d], let info = decks.first(where: { $0.deck == d }),
                  let k1 = idx.firstIndex(of: c), let k2 = idx.firstIndex(of: o),
                  let a = texts[k1].flatMap(TimeFields.parse), let b = texts[k2].flatMap(TimeFields.parse) else { continue }
            let e = bound[c].kind == .elapsed ? a : b, rem = bound[c].kind == .elapsed ? b : a
            if abs((e.minus ? -e.seconds : e.seconds) + rem.seconds - Double(info.lengthMs) / 1000) > 1.0 {
                pairBad[d, default: 0] += 1
                if pairBad[d]! >= 2 { drop.insert(d); log("Bildschirm: Deck \(d) passt nicht mehr (Laufzeit + Restzeit ≠ Länge), neu einmessen") }
            } else {
                pairBad[d] = 0
            }
        }
        if !drop.isEmpty {
            bound.removeAll { drop.contains($0.deck) }
            nextCalibration = .distantPast
            return
        }
        for (k, i) in idx.enumerated() where chosen.values.contains(i) {
            let b = bound[i]
            guard let info = decks.first(where: { $0.deck == b.deck }) else { continue }
            let tracker = trackers[b.deck] ?? PositionTracker(lengthMs: info.lengthMs)
            trackers[b.deck] = tracker
            var ms: Int64?
            if let t = texts[k], TimeFields.isEnd(t) {
                ms = info.lengthMs
            } else if let t = texts[k], let v = TimeFields.parse(t) {
                // Elapsed with minus: before the track start. Remaining: the minus is only the format (stack/library).
                ms = b.kind == .elapsed ? Int64((v.minus ? -v.seconds : v.seconds) * 1000) : info.lengthMs - Int64(v.seconds * 1000)
            }
            bound[i].misses = ms == nil ? b.misses + 1 : 0
            let jumpBefore = tracker.lastJump.map { "\($0.from)>\($0.to)" }
            // While a toolbar change is being checked, a jump is held only if the field might show another deck now:
            // its value is that deck's elapsed or remaining time. A hot cue the DJ presses meanwhile counts at once.
            var allowJump = !suspect
            if suspect, let t = texts[k], let v = TimeFields.parse(t) {
                let shown = v.seconds * 1000
                allowJump = !trackers.contains { d, other in
                    guard d != b.deck, let e = other.expected(at: now), let len = decks.first(where: { $0.deck == d })?.lengthMs else { return false }
                    return abs(shown - Double(e)) < 1500 || abs(shown - Double(len - e)) < 1500
                }
            }
            let changed = tracker.feed(ms, at: now, allowJump: allowJump)
            if ScreenTimeReader.debugReadings {
                log("roh Deck \(b.deck) \(b.kind == .elapsed ? "L" : "R") \(texts[k] ?? "-") → \(ms.map(String.init) ?? "-") pos \(tracker.positionMs.map(String.init) ?? "-") \(tracker.playing ? "play" : "pause")\(changed ? " *" : "")")
            }
            if Sender.debugPositions, let ms, !changed, tracker.hasPendingJump {
                log("Bildschirm: gehalten Deck \(b.deck) \(ms) (erwartet \(tracker.expected(at: now) ?? -1), \(suspect ? "Prüfung" : "Sprung?"), gelesen \(texts[k] ?? "-"))")
            }
            if let j = tracker.lastJump, "\(j.from)>\(j.to)" != jumpBefore, ProcessInfo.processInfo.environment["LJL_DEBUG_POSITIONS"] == "1" {
                log("Bildschirm: Sprung Deck \(b.deck) \(j.from) → \(j.to) ms (gelesen: \(texts[k] ?? "-"))")
            }
            // Send on every change, and once a second while playing so LJ Link can correct its own running clock.
            let due = now.timeIntervalSince(lastSent[b.deck] ?? .distantPast) >= 1
            // The resend only with a reading confirmed in this frame: during a held jump (e.g. right after a layout
            // change) it repeated the old value every second and pulled LJ Link's playhead back each time.
            if let pos = tracker.positionMs, changed || (tracker.playing && due && tracker.lastAccepted == now) {
                lastSent[b.deck] = now
                announced.insert(b.deck)
                onPosition(b.deck, pos, tracker.playing, tracker.speed)
            }
        }
    }

    /// Development: every reading of every bound field (LJL_DEBUG_READINGS=1).
    static let debugReadings = ProcessInfo.processInfo.environment["LJL_DEBUG_READINGS"] == "1"

    // MARK: Vision

    static func recognize(_ cg: CGImage, fast: Bool = false) -> [VNRecognizedTextObservation] {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = fast ? .fast : .accurate
        r.usesLanguageCorrection = false
        r.recognitionLanguages = ["en-US"]
        try? VNImageRequestHandler(cgImage: cg, orientation: .up).perform([r])
        return r.results ?? []
    }

    static func save(_ cg: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])

    static func scaled(_ cg: CGImage, _ f: CGFloat) -> CGImage {
        guard f != 1 else { return cg }
        let i = CIImage(cgImage: cg).applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: f, kCIInputAspectRatioKey: 1.0])
        return sharedContext.createCGImage(i, from: i.extent.integral) ?? cg
    }

    /// Calibration: overlapping tiles over the upper 55 % of the window (all deck areas of all layouts), each scaled to
    /// about 1000 px width, because Vision shrinks large images and loses the small digits.
    public static func findFields(_ cg: CGImage) -> ([TimeField], [TextSpot]) {
        let W = CGFloat(cg.width), H = CGFloat(cg.height), deckH = H * 0.55
        let tileW = W / 4, tileH = deckH / 4
        var fields: [TimeField] = []
        var texts: [TextSpot] = []
        var y: CGFloat = 0
        while y < deckH {
            var x: CGFloat = 0
            while x < W {
                let rect = CGRect(x: x, y: y, width: tileW, height: tileH).intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
                x += tileW / 2
                guard rect.width > 8, rect.height > 8, let tile = cg.cropping(to: rect) else { continue }
                for o in recognize(scaled(tile, 1000 / rect.width)) {
                    guard let c = o.topCandidates(1).first else { continue }
                    let b = o.boundingBox
                    let r = CGRect(x: rect.minX + b.minX * rect.width, y: rect.minY + (1 - b.maxY) * rect.height,
                                   width: b.width * rect.width, height: b.height * rect.height)
                    if c.string.range(of: #"\d{1,2}:\d{2}\.\d{2}"#, options: .regularExpression) != nil { continue } // track list
                    if let v = TimeFields.parse(c.string) {
                        // Box of just the time inside the line; if Vision cannot give it, the whole line's box.
                        var fr = r
                        if let range = c.string.range(of: #"-?\s?\d{1,2}:\d{2}[.:,]\d"#, options: .regularExpression),
                           let sub = (try? c.boundingBox(for: range))??.boundingBox {
                            fr = CGRect(x: rect.minX + sub.minX * rect.width, y: rect.minY + (1 - sub.maxY) * rect.height,
                                        width: sub.width * rect.width, height: sub.height * rect.height)
                        }
                        if !fields.contains(where: { ScreenTimeReader.same($0.rect, fr) }) {
                            fields.append(TimeField(rect: fr, seconds: v.seconds, minus: v.minus))
                        }
                    } else if !texts.contains(where: { $0.rect.intersects(r) && $0.text == c.string }) {
                        texts.append(TextSpot(rect: r, text: c.string))
                    }
                }
            }
            y += tileH / 2
        }
        return (fields, texts)
    }

    /// The same field seen twice (overlapping tiles): more than half of the smaller box is shared. Stacked fields of
    /// a platter (elapsed above remaining) touch or overlap by a few pixels and must stay two fields.
    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        guard !i.isNull else { return false }
        return i.width * i.height > 0.5 * min(a.width * a.height, b.width * b.height)
    }

    /// Reads one field: crop with a margin, scaled so the digits are about 40 px high; the line nearest the middle.
    static func readText(_ cg: CGImage, _ r: CGRect) -> String? {
        let pad = r.insetBy(dx: -r.height * 0.6, dy: -r.height * 0.25).integral
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let crop = cg.cropping(to: pad) else { return nil }
        return readCrop(crop, textHeight: r.height)
    }

    /// Vision on an already cut crop, scaled so the digits are about 40 px high; the line nearest the middle.
    public static func readCrop(_ crop: CGImage, textHeight: CGFloat) -> String? {
        readCropWithBoxes(crop, textHeight: textHeight)?.text
    }

    /// Like readCrop, plus the x range (pixels of `crop`) of the recognised line – where the time string is, which
    /// DigitReader uses to place its slots. (Vision's per-character boxes are not usable: each is the whole line.)
    public static func readCropWithBoxes(_ crop: CGImage, textHeight: CGFloat) -> (text: String, line: ClosedRange<Int>)? {
        let big = scaled(crop, max(1, 40 / textHeight))
        // Accurate level only: the fast one misreads digits now and then (8 as 3), and the digit reader learns from
        // these readings – a wrong lesson would stick.
        let obs = recognize(big).sorted { abs($0.boundingBox.midY - 0.5) < abs($1.boundingBox.midY - 0.5) }
        guard let o = obs.first, let c = o.topCandidates(1).first else { return nil }
        let x0 = Int((o.boundingBox.minX * CGFloat(crop.width)).rounded(.down))
        let x1 = Int((o.boundingBox.maxX * CGFloat(crop.width)).rounded(.up)) - 1
        return (c.string, max(0, x0)...max(x0, min(crop.width - 1, x1)))
    }

    /// 32×10 grey thumbnail: equal thumbnails = the display did not change.
    static func thumbnail(_ cg: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 32 * 10)
        guard let ctx = CGContext(data: &px, width: 32, height: 10, bitsPerComponent: 8, bytesPerRow: 32,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 10))
        return px
    }
}

/// Frames are handled on `frames`, calibration hands its result back there; the start/stop calls only touch the stream.
extension ScreenTimeReader: @unchecked Sendable {}

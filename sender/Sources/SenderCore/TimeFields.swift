import CoreGraphics
import Foundation

/// A time display found in the Serato window: where it is and what it showed when it was found.
public struct TimeField: Equatable, Sendable {
    public var rect: CGRect        // pixels, origin top-left
    public var seconds: Double     // value as shown (always positive)
    public var minus: Bool         // shown with a minus sign (remaining time in the stack/library layouts)
    public init(rect: CGRect, seconds: Double, minus: Bool) { self.rect = rect; self.seconds = seconds; self.minus = minus }
}

/// Text Vision found during calibration (titles of the decks are among these).
public struct TextSpot: Equatable, Sendable {
    public var rect: CGRect
    public var text: String
    public init(rect: CGRect, text: String) { self.rect = rect; self.text = text }
}

/// What the sender knows about a deck from Serato's log and the file's tags.
public struct DeckInfo: Equatable, Sendable {
    public var deck: Int
    public var lengthMs: Int64
    public var title: String?
    public init(deck: Int, lengthMs: Int64, title: String?) { self.deck = deck; self.lengthMs = lengthMs; self.title = title }
}

/// Which deck a time field shows and whether it counts up (elapsed) or down (remaining).
public struct Binding: Equatable, Sendable {
    public enum Kind: String, Sendable { case elapsed, remaining }
    public var field: Int     // index into the calibrated fields
    public var deck: Int
    public var kind: Kind
    public init(field: Int, deck: Int, kind: Kind) { self.field = field; self.deck = deck; self.kind = kind }
}

/// Parsing and assigning of Serato's time displays (concept 5.3a). Pure logic, testable without a screen.
public enum TimeFields {
    /// "04:18.3", "-04:18:3" (stack/library), "00:00.0". The track list uses two decimals and is not matched.
    static let pattern = try! NSRegularExpression(pattern: #"(-?)\s?(\d{1,2}):(\d{2})[.:,](\d)(?!\d)"#)

    public static func parse(_ s: String) -> (seconds: Double, minus: Bool)? {
        let ns = s as NSString
        guard let m = pattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        guard let mm = Double(ns.substring(with: m.range(at: 2))), let ss = Double(ns.substring(with: m.range(at: 3))),
              let t = Double(ns.substring(with: m.range(at: 4))), ss < 60 else { return nil }
        return (mm * 60 + ss + t / 10, ns.substring(with: m.range(at: 1)) == "-")
    }

    /// Serato shows "--:--.-" once a deck has played to the end.
    public static func isEnd(_ s: String) -> Bool { s.contains("--:--") }

    /// Looser, for assigning a field only: Serato's "--:--.-" under an ended deck's elapsed time, as Vision reads it
    /// when the needle crosses it ("-*--"): dashes and separators only, at least two dashes.
    static func looksLikeEnd(_ s: String) -> Bool {
        let t = s.replacingOccurrences(of: " ", with: "")
        return t.filter({ $0 == "-" || $0 == "–" || $0 == "—" }).count >= 2 && t.allSatisfy { "-–—*.:·•_".contains($0) }
    }

    /// Assigns fields to decks.
    /// 1. Pairs: two fields whose values add up to a deck's length (±0.35 s) are that deck's elapsed and remaining time
    ///    (platter layouts). The upper one, or the one without minus, is elapsed.
    /// 2. Single fields: the deck whose title stands to the left in the same row (stack and library layouts).
    /// 3. Otherwise: the only deck that is long enough for the shown remaining time.
    /// `previous`: where decks were seen before in the same layout. When several decks fit equally (the same track on
    /// two decks, "instant double", or two tracks of equal length), the deck that was at that place wins.
    /// `width`: window width in pixels. Last tie-break: decks 1 and 3 sit in the left half, 2 and 4 in the right half
    /// in every layout except the stack (checked on Serato DJ Pro 5.0 captures of all layouts).
    public static func bind(fields: [TimeField], texts: [TextSpot], decks: [DeckInfo],
                            previous: [(rect: CGRect, deck: Int)] = [], width: CGFloat? = nil) -> [Binding] {
        func near(_ r: CGRect) -> Int? {
            previous.first { p in
                let i = p.rect.intersection(r)
                return !i.isNull && i.width * i.height > 0.5 * min(p.rect.width * p.rect.height, r.width * r.height)
            }?.deck
        }
        func pick(_ hits: [(deck: Int, l: Double)], at r: CGRect) -> Int? {
            if hits.count == 1 { return hits[0].deck }
            if let d = near(r), hits.contains(where: { $0.deck == d }) { return d }
            if let w = width {
                let side = hits.filter { ($0.deck % 2 == 1) == (r.midX < w / 2) }
                if side.count == 1 { return side[0].deck }
            }
            return nil
        }
        var out: [Binding] = []
        var used = Set<Int>()
        var bound = Set<Int>()
        let lengths = decks.map { (deck: $0.deck, l: Double($0.lengthMs) / 1000) }

        // 1. pairs
        for i in fields.indices where !used.contains(i) {
            for j in fields.indices where j > i && !used.contains(j) {
                let a = fields[i], b = fields[j]
                guard abs(a.rect.midX - b.rect.midX) < max(a.rect.width, b.rect.width) * 1.5,
                      abs(a.rect.midY - b.rect.midY) < max(a.rect.height, b.rect.height) * 3 else { continue }
                // A minus on a platter's elapsed time means "before the track start" (e.g. playing backwards past
                // the start): elapsed counts negative there, while the remaining time is larger than the track.
                func signed(_ f: TimeField) -> Double { f.minus ? -f.seconds : f.seconds }
                let sumAElapsed = signed(a) + b.seconds, sumBElapsed = a.seconds + signed(b)
                let hitsA = lengths.filter { abs($0.l - sumAElapsed) <= 0.35 && !bound.contains($0.deck) }
                let hitsB = lengths.filter { abs($0.l - sumBElapsed) <= 0.35 && !bound.contains($0.deck) }
                var aElapsed: Bool
                var d: Int
                if a.minus == b.minus {
                    // Same sign: the sums are equal; the upper field of a platter is the elapsed time.
                    guard let h = pick(hitsA, at: a.rect) else { continue }
                    aElapsed = a.rect.midY < b.rect.midY
                    d = h
                } else if let h = pick(hitsA, at: a.rect) {
                    aElapsed = true; d = h
                } else if let h = pick(hitsB, at: a.rect) {
                    aElapsed = false; d = h
                } else { continue }
                out.append(Binding(field: i, deck: d, kind: aElapsed ? .elapsed : .remaining))
                out.append(Binding(field: j, deck: d, kind: aElapsed ? .remaining : .elapsed))
                used.formUnion([i, j])
                bound.insert(d)
            }
        }
        // 2. title to the left in the same row. Single fields only with a minus: that is the remaining time of the
        //    stack/library layouts. A single field without minus can be a platter's elapsed OR remaining time (its
        //    partner hidden by the needle); taking it as remaining made a playing deck run backwards. Such a field
        //    waits for its partner (the next calibration re-reads it).
        //    All (field, deck) pairs are scored first and the best go first, so a field cannot take a deck whose
        //    title stands in the next row while that deck's own field comes later (library, 4 decks).
        var cands: [(field: Int, deck: Int, score: CGFloat)] = []
        for i in fields.indices where !used.contains(i) && fields[i].minus {
            let f = fields[i]
            for d in decks where !bound.contains(d.deck) {
                guard let title = d.title.map(normalize), title.count >= 3 else { continue }
                // The same title on two decks (instant double) tells nothing: better no position than the wrong deck.
                if decks.filter({ $0.title.map(normalize) == title }).count > 1 { continue }
                for t in texts where t.rect.maxX <= f.rect.minX + 4 {
                    // Same row, or the title one line above the time (the stack layout: title on the first line of
                    // the deck, the remaining time on the second, about 1.6 text heights lower).
                    let dy = abs(t.rect.midY - f.rect.midY)
                    guard dy < max(f.rect.height, t.rect.height) * 2.2 else { continue }
                    let seen = normalize(t.text)
                    let probe = String(title.prefix(12))
                    guard seen.contains(probe) || (seen.count >= 6 && title.hasPrefix(String(seen.prefix(12)))) else { continue }
                    // The row counts first: a longer title in the next row ends nearer to the field.
                    cands.append((i, d.deck, dy * 20 + (f.rect.minX - t.rect.maxX)))
                }
            }
        }
        for c in cands.sorted(by: { $0.score < $1.score }) where !used.contains(c.field) && !bound.contains(c.deck) {
            out.append(Binding(field: c.field, deck: c.deck, kind: .remaining))
            used.insert(c.field)
            bound.insert(c.deck)
        }
        // 3. the only deck long enough (again only fields with a minus)
        for i in fields.indices where !used.contains(i) && fields[i].minus {
            let cands = lengths.filter { !bound.contains($0.deck) && $0.l + 0.35 >= fields[i].seconds }
            if let d = pick(cands, at: fields[i].rect) {
                out.append(Binding(field: i, deck: d, kind: .remaining))
                used.insert(i)
                bound.insert(d)
            }
        }
        // 4. A platter field whose partner the needle hides. On a paused deck the needle stands still and may cover a
        //    digit for good; the cut partner is still there as text with a colon ("00:07."). Partner above: this is
        //    the remaining time, below: the elapsed time. (A colon is required: the BPM above the platter has none.)
        //    At the end of a track the partner is "--:--.-" (below the elapsed time, which then keeps counting past the
        //    length while the deck stays on play): such a field is the elapsed time of a deck that has ended.
        // The other field of an already bound platter (stacked right above/below it): same deck, other time.
        func stacked(_ g: TimeField) -> (deck: Int, kind: Binding.Kind)? {
            for b in out {
                let f = fields[b.field]
                guard abs(g.rect.midX - f.rect.midX) < max(f.rect.width, g.rect.width) * 0.6,
                      abs(g.rect.midY - f.rect.midY) < max(f.rect.height, g.rect.height) * 3,
                      abs(g.rect.midY - f.rect.midY) > min(f.rect.height, g.rect.height) * 0.5 else { continue }
                let kind: Binding.Kind = g.rect.midY < f.rect.midY ? .elapsed : .remaining
                if kind != b.kind && !out.contains(where: { $0.deck == b.deck && $0.kind == kind }) { return (b.deck, kind) }
            }
            return nil
        }
        for i in fields.indices where !used.contains(i) && !fields[i].minus {
            let f = fields[i]
            // First: is it the partner of a field bound just before (QS 4, A3: the misread elapsed time of deck 1 went
            // to deck 2 when deck 1's remaining time came first)?
            if let s = stacked(f) {
                out.append(Binding(field: i, deck: s.deck, kind: s.kind))
                used.insert(i)
                continue
            }
            func beside(_ t: TextSpot) -> Bool {
                let dy = abs(t.rect.midY - f.rect.midY)
                return abs(t.rect.midX - f.rect.midX) < f.rect.width && dy > f.rect.height * 0.6 && dy < f.rect.height * 2.5
            }
            // A partner with digits first; a loose end marker only if there is none (QS 5, K4).
            guard let p = texts.first(where: { beside($0) && ($0.text.range(of: #"\d{1,2}\s*:\s*\d"#, options: .regularExpression) != nil || isEnd($0.text)) })
                    ?? texts.first(where: { beside($0) && looksLikeEnd($0.text) && $0.rect.midY > f.rect.midY }) else { continue }
            let ended = (isEnd(p.text) || looksLikeEnd(p.text)) && p.rect.midY > f.rect.midY
            let cands = lengths.filter {
                !bound.contains($0.deck) && (ended ? f.seconds >= $0.l - 1 : $0.l + 0.35 >= f.seconds)
            }
            if let d = pick(cands, at: f.rect) {
                out.append(Binding(field: i, deck: d, kind: p.rect.midY < f.rect.midY ? .remaining : .elapsed))
                used.insert(i)
                bound.insert(d)
            }
        }
        // 5. The other field of a bound platter: stacked right above or below a bound field, it is the same deck's
        //    other time (upper = elapsed). Needed when the needle hides a digit of one field so the pair rule cannot
        //    add up the two (a paused deck keeps it hidden): then the readable field still has its deck.
        for i in fields.indices where !used.contains(i) {
            if let s = stacked(fields[i]) {
                out.append(Binding(field: i, deck: s.deck, kind: s.kind))
                used.insert(i)
            }
        }
        return out.sorted { $0.field < $1.field }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// Turns raw readings of one deck into a steady position: rejects misreadings, confirms jumps and tells play from pause.
public final class PositionTracker {
    public let lengthMs: Int64
    public private(set) var positionMs: Int64?
    public private(set) var playing = false
    private var lastAt: Date?
    private var pendingJump: (ms: Int64, at: Date)?
    /// Recent moves of the display (last 2 s), from where and when to where and when: they tell a short loop
    /// (forward, forward, back …) from a pause and from playing backwards.
    private var moves: [(fromMs: Int64, fromAt: Date, ms: Int64, at: Date)] = []

    private func record(from p: Int64, _ pAt: Date, to ms: Int64, at now: Date) {
        moves.append((p, pAt, ms, now))
        moves.removeAll { now.timeIntervalSince($0.at) > 2 }
    }

    /// The last 2 s look like a short loop (½-2 beats): steps forward and back, at least three in all, the last step
    /// back within 1.5 s and shorter than 0.7 s (2 s from the second step back on). Inside such a loop the display can show the same value twice in a row
    /// (123.4, 123.4, 123.3, 123.5 …); that is no pause, or LJ Link's PAUSE blinked every half second. A paused deck
    /// nudged forward and back is no loop (only two steps; QS 5, S2).
    private func looping(at now: Date) -> Bool {
        let recent = moves.filter { now.timeIntervalSince($0.at) <= 2 }
        let forward = recent.filter { $0.ms > $0.fromMs }.count, backward = recent.filter { $0.ms < $0.fromMs }.count
        guard forward >= 1, backward >= 1, forward + backward >= 3,
              let back = recent.last(where: { $0.ms < $0.fromMs }), now.timeIntervalSince(back.at) <= 1.5 else { return false }
        // A single step back up to 0.7 s (½-1 beat); a CUE pressed while playing goes back further and then pauses
        // (QS 6, S1). From the second step back on, loops up to 2 s.
        return back.fromMs - back.ms < (backward >= 2 ? 2_000 : 700)
    }

    /// The last two moves both went back, together at least at half speed: the deck plays backwards. (A loop read at
    /// an unlucky rhythm also seems to go back twice, but slowly: 0.35 s reads of a 0.48 s loop lose 0.13 s each.)
    private var reversing: Bool {
        guard moves.count >= 2 else { return false }
        let a = moves[moves.count - 2], b = moves[moves.count - 1]
        return a.ms < a.fromMs && b.ms < b.fromMs && PositionTracker.reverseLike(from: (a.fromMs, a.fromAt), to: (b.ms, b.at))
    }

    /// Readings past the end that run on like a clock: the first and the last one.
    private var pendingEnd: (first: (ms: Int64, at: Date), last: (ms: Int64, at: Date))?

    /// `b` follows `a` like the display of a deck: the same (paused) or later by up to 1.6× the time in between
    /// (playing, up to +60 % tempo), with 0.15 s for the display's 0.1 s steps; never backwards.
    static func clockLike(from a: (ms: Int64, at: Date), to b: (ms: Int64, at: Date)) -> Bool {
        let dt = b.at.timeIntervalSince(a.at) * 1000
        return dt > 0 && Double(b.ms) >= Double(a.ms) - 150 && Double(b.ms) <= Double(a.ms) + dt * 1.6 + 150
    }

    /// `b` follows `a` like a deck playing backwards (Serato's reverse, censor): earlier by 0.5-1.6× the time in
    /// between. Slower drifts back (misreadings at a track's end: 0.1×) do not count.
    static func reverseLike(from a: (ms: Int64, at: Date), to b: (ms: Int64, at: Date)) -> Bool {
        let dt = b.at.timeIntervalSince(a.at) * 1000
        return dt >= 150 && Double(b.ms) <= Double(a.ms) - dt * 0.5 + 100 && Double(b.ms) >= Double(a.ms) - dt * 1.6 - 150
    }
    /// A jump is waiting for confirmation: the caller should confirm it with an independent reader (Vision), since
    /// the same reader can repeat its own misreading.
    /// Also while readings past the end wait for confirmation: the own digit reader once read "62:15" for "02:15"
    /// steadily for a second; Vision does not.
    public var hasPendingJump: Bool { pendingJump != nil || pendingEnd != nil }
    /// The last accepted jump (from, to), for the development log.
    public private(set) var lastJump: (from: Int64, to: Int64)?

    /// Readings of the current run (playing, no jump), for the speed: the last 8 s.
    private var run: [(t: Date, ms: Int64)] = []
    /// Playing speed (1.0 = no pitch) from the last 5-8 s of readings; nil until known (LJ Link then runs at 1.0). The display has 0.1 s steps,
    /// so a single step says little. Simulated: over 8 s a straight line is off by 0.1 % typically, 0.5 % at worst in
    /// 19 of 20 cases (over 4 s: 0.3 % and 1.8 %).
    public var speed: Double? {
        guard playing, let first = run.first, let last = run.last, last.t.timeIntervalSince(first.t) >= 5, run.count >= 20 else { return nil }
        let xs = run.map { $0.t.timeIntervalSince(first.t) * 1000 }, ys = run.map { Double($0.ms) }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        var sxy = 0.0, sxx = 0.0
        for i in xs.indices { sxy += (xs[i] - mx) * (ys[i] - my); sxx += (xs[i] - mx) * (xs[i] - mx) }
        guard sxx > 0 else { return nil }
        let v = sxy / sxx
        return v > 0.5 && v < 1.5 ? v : nil
    }

    public init(lengthMs: Int64) { self.lengthMs = lengthMs }

    /// When the last reading was taken as the deck's position (also unchanged while paused). A resend of the position
    /// is only right if it was just confirmed; a held reading (pending jump) must not repeat the old value.
    public private(set) var lastAccepted: Date?

    /// Where the deck should be at `t`, from the last accepted reading (for checking a place after a layout change).
    public func expected(at t: Date) -> Int64? {
        guard let p = positionMs, let a = lastAt else { return nil }
        return p + (playing ? Int64(max(0, t.timeIntervalSince(a)) * 1000 * (speed ?? 1)) : 0)
    }

    private func note(_ ms: Int64, _ now: Date, newRun: Bool) {
        if newRun || !playing { run.removeAll() }
        guard playing else { return }
        run.append((now, ms))
        while let f = run.first, now.timeIntervalSince(f.t) > 8 { run.removeFirst() }
    }

    /// Feeds one reading (position in ms from the track start, or nil if unreadable). Returns true if the position or
    /// play state changed in a way LJ Link should hear about.
    @discardableResult
    /// `allowJump: false` while the reader is not sure its places still show this deck (Serato's toolbar changed): a
    /// jump then stays pending instead of being confirmed, so another deck's time can never be taken over.
    public func feed(_ reading: Int64?, at now: Date = Date(), allowJump: Bool = true) -> Bool {
        // Outside the track is a misreading, except before the start: Serato shows negative elapsed time when a deck
        // plays backwards past the start (sent as 0).
        // Past the end: when a track ends and the deck stays on play, Serato's elapsed time keeps counting beyond the
        // file's length (05:50.9 for a 04:45.32 track) while the remaining time shows "--:--.-". At the end already,
        // that is the end. Otherwise it is the end only when such readings run on like a clock for 1 s (misreadings
        // do not): this also repairs a position that a misreading had taken away from the end.
        guard var reading, reading >= -600_000 else { return false }
        if reading > lengthMs + 400 {
            if let p = positionMs, p >= lengthMs - 200 {
                reading = lengthMs
            } else if let e = pendingEnd, PositionTracker.clockLike(from: e.last, to: (reading, now)),
                      PositionTracker.clockLike(from: e.first, to: (reading, now)) {
                // At least 1 s of it: a real display after the end counts on steadily, misreadings do not.
                guard now.timeIntervalSince(e.first.at) >= 1 else { pendingEnd = (e.first, (reading, now)); return false }
                pendingEnd = nil; pendingJump = nil
                if let p = positionMs { lastJump = (p, lengthMs) }
                positionMs = lengthMs; lastAt = now; lastAccepted = now; playing = false
                note(lengthMs, now, newRun: true)
                return true
            } else {
                pendingEnd = ((reading, now), (reading, now))
                return false
            }
        }
        let ms = min(max(0, reading), lengthMs)
        guard let pos = positionMs, let last = lastAt else {
            positionMs = ms; lastAt = now; lastAccepted = now; note(ms, now, newRun: true); return true
        }
        let dt = now.timeIntervalSince(last) * 1000
        let expected = Double(pos) + (playing ? dt : 0)
        let diff = Double(ms) - expected
        // Within reach of the running position (display has 0.1 s steps; tempo can be up to ±50 %).
        if abs(diff) <= max(350, dt * 0.6) || (abs(Double(ms - pos)) <= 150) {
            let moved = ms != pos
            let wasPlaying = playing
            // Forward: playing. A small step back keeps the state (a short loop while playing), sets it to playing when
            // the moves look like a loop, and to not playing when the deck plays backwards.
            if moved {
                record(from: pos, last, to: ms, at: now)
                if ms > pos { playing = true } else if reversing { playing = false } else if looping(at: now) { playing = true }
            } else if dt > 350, !looping(at: now) {
                playing = false
            }
            pendingJump = nil
            pendingEnd = nil
            lastAccepted = now
            let changed = moved || wasPlaying != playing
            // A step back (short loop) starts a new run for the speed; so does starting to play.
            if moved { note(ms, now, newRun: ms < pos || !wasPlaying) } else if !playing { note(ms, now, newRun: true) }
            if moved || !playing { positionMs = ms; lastAt = now }
            return changed
        }
        // A jump (loop, cue, needle drop) counts only when the next reading confirms it like a clock: the same value
        // (paused) or later by about the time in between (playing). Before, "within 0.4 s" was enough, and misreadings
        // at a track's end (04:43.9, 04:43.7, 04:43.5 …) confirmed each other.
        if !allowJump { if pendingJump == nil { pendingJump = (ms, now) }; return false }
        if let p = pendingJump, PositionTracker.clockLike(from: p, to: (ms, now)) {
            // A loop's way back read 0.3-0.4 s apart comes as such a jump.
            record(from: pos, last, to: p.ms, at: p.at); record(from: p.ms, p.at, to: ms, at: now)
            if ms < pos, looping(at: now) { playing = true }
            lastJump = (pos, ms)
            positionMs = ms; lastAt = now; pendingJump = nil; lastAccepted = now
            note(ms, now, newRun: true)
            return true
        }
        // Playing backwards: confirmed like a clock running back. Reported as not playing (forwards), so LJ Link does
        // not run the playhead on the wrong way; each following step back is a small step and is followed.
        if let p = pendingJump, PositionTracker.reverseLike(from: p, to: (ms, now)) {
            lastJump = (pos, ms)
            // Inside a short loop this is the loop's way back (1 beat, QS 5, S1): it keeps playing.
            record(from: pos, last, to: p.ms, at: p.at); record(from: p.ms, p.at, to: ms, at: now)
            playing = !reversing && looping(at: now)
            positionMs = ms; lastAt = now; pendingJump = nil; lastAccepted = now
            note(ms, now, newRun: true)
            return true
        }
        pendingJump = (ms, now)
        return false
    }
}

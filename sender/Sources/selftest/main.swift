// Self test of SenderCore (no XCTest with the Command Line Tools). `swift run selftest`; exit code 1 on a failure.
import AVFoundation
import CoreGraphics
import Foundation
import SenderCore

var failures = 0
func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

// MARK: Serato log
// Lines as Serato DJ Pro 5.0.0 wrote them on 14 Nov 2026 (path shortened, "&" in a file name on purpose).
let log = """
I20261114 08:24:34.12 1 :0] [Audio] Creating audio cache store resource for 'cache://stem-/Users/x/Music/27 - Rihanna - S&M.flac-vocals-version-1.2?sample_rate=44100&length=10739820'
I20261114 08:24:34.13 1 :0] [Audio] Creating audio cache store resource for 'cache:///Users/x/Music/27 - Rihanna - S&M.flac:deck_0_instrumental?sample_rate=44100&length=10739820'
I20261114 08:25:24.20 1 :0] [Audio] Creating audio cache store resource for 'cache:///Users/x/Music/92 - Black Eyed Peas - I Gotta Feeling 2.flac:deck_1_instrumental?sample_rate=48000&length=12750780'
"""
let loads = SeratoLog.loads(in: log)
check(loads.count == 2, "two deck loads, stem caches ignored")
check(loads.first?.deck == 1 && loads.first?.file.lastPathComponent == "27 - Rihanna - S&M.flac", "deck_0 is deck 1, file name with &")
check(loads.first?.lengthMs == 243_533, "length from samples and rate (10739820 / 44100)")
check(loads.last?.deck == 2 && loads.last?.sampleRate == 48000, "deck_1 is deck 2 with its own rate")

// Follower: new lines appended to the newest log are reported once.
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ljl-selftest-\(UUID().uuidString)")
let logs = tmp.appendingPathComponent("Logs")
try! FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
let logFile = logs.appendingPathComponent("20261114-082412.1.log")
try! "start\n".write(to: logFile, atomically: true, encoding: .utf8)
try! FileManager.default.createSymbolicLink(atPath: logs.appendingPathComponent("DJ.INFO").path, withDestinationPath: logFile.lastPathComponent)
let follower = SeratoLogFollower(seratoFolder: tmp)
check(follower.current().isEmpty, "nothing loaded at start")
let h = try! FileHandle(forWritingTo: logFile)
h.seekToEndOfFile()
h.write(log.data(using: .utf8)!)
h.write("\n".data(using: .utf8)!)
check(follower.poll().count == 2, "appended loads are reported")
check(follower.poll().isEmpty, "and only once")
h.write("I x ['cache:///Users/x/Music/27 - Rihanna - S&M.flac:deck_0_instrumental?sample_rate=44100&length=10739820'\n".data(using: .utf8)!)
check(follower.poll().isEmpty, "same file on the same deck again is not a new load")
h.write("I x ['cache:///Users/x/Music/new.mp3:deck_0_instrumental?sample_rate=44100&length=441000'\n".data(using: .utf8)!)
check(follower.poll().first?.file.lastPathComponent == "new.mp3", "another file on deck 1 is reported")
try? h.close()

// MARK: Waveforms
// 3 s test tone: 1 s 80 Hz (low), 1 s 1 kHz (mid), 1 s 8 kHz (high).
let rate = 44100.0
let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
let wav = tmp.appendingPathComponent("tone.wav")
do {
    let f = try AVAudioFile(forWriting: wav, settings: fmt.settings)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(rate * 3))!
    buf.frameLength = buf.frameCapacity
    for i in 0..<Int(rate * 3) {
        let freq = i < Int(rate) ? 80.0 : (i < Int(rate * 2) ? 1000.0 : 8000.0)
        let v = Float(sin(2 * Double.pi * freq * Double(i) / rate) * 0.5)
        buf.floatChannelData![0][i] = v
        buf.floatChannelData![1][i] = v
    }
    try f.write(from: buf)
}
let w = try! WaveformBuilder.build(from: wav)
check(abs(w.detailFrames - 450) <= 1, "150 detail entries per second (3 s -> 450, got \(w.detailFrames))")
check(w.overview.count == Waveforms.overviewCount * 4, "overview has \(Waveforms.overviewCount) entries")
func band(_ second: Int) -> (Int, Int, Int) {
    let i = (second * 150 + 75) * 4   // middle of that second
    return (Int(w.detail[i]), Int(w.detail[i + 1]), Int(w.detail[i + 2]))
}
let (l0, m0, h0) = band(0), (l1, m1, h1) = band(1), (l2, m2, h2) = band(2)
check(l0 > 200 && m0 < 60 && h0 < 20, "80 Hz lands in low (\(l0), \(m0), \(h0))")
check(m1 > 150 && l1 < 60 && h1 < 60, "1 kHz lands in mid at 75 % weight (\(l1), \(m1), \(h1))")
check(h2 > 100 && l2 < 20 && m2 < 60, "8 kHz lands in high at 50 % weight (\(l2), \(m2), \(h2))")
let ov = w.overview
check((0..<Waveforms.overviewCount).allSatisfy { ov[$0 * 4] <= ov[$0 * 4 + 1] && ov[$0 * 4 + 1] <= ov[$0 * 4 + 2] }, "overview heights are cumulative (low <= low+mid <= all)")
check(w.detail.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 0 }, "fourth byte stays 0 (LJ Link three-band format)")

// MARK: Club config
let club = ClubConfig(version: 1, club: "Testclub", hosts: ["10.0.0.5"], port: 8080, key: "abc")
let enc = try! JSONEncoder().encode(club)
check((try? JSONDecoder().decode(ClubConfig.self, from: enc)) == club, "club.json round trip")

// MARK: Protocol messages
func obj(_ m: Message) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: m.json.data(using: .utf8)!) as? [String: Any]) ?? [:]
}
let hello = obj(.hello(key: "k", name: String(repeating: "x", count: 80), software: "Serato DJ Pro", app: "0.1", names: false))
check(hello["type"] as? String == "hello" && hello["protocol"] as? Int == 1, "hello carries protocol 1")
check((hello["name"] as? String)?.count == 64, "name cut to 64 characters")
check(hello["names"] as? Bool == false, "names flag sent")
let noNames = obj(.load(deck: 1, id: "a", lengthMs: 1000, bpm: nil, key: nil, title: nil, artist: nil))
check(noNames["title"] == nil && noNames["artist"] == nil, "load without names has no title or artist")
let wf = obj(.waveform(deck: 2, id: "a", kind: "detail", entries: 2, data: [1, 2, 3, 0, 4, 5, 6, 0]))
check(wf["fps"] as? Int == 150 && wf["entries"] as? Int == 2, "detail waveform has fps 150 and entries")
check(Data(base64Encoded: wf["data"] as? String ?? "") == Data([1, 2, 3, 0, 4, 5, 6, 0]), "waveform data is base64 of the raw bytes")
check(obj(.waveform(deck: 2, id: "a", kind: "overview", entries: 1, data: [0, 0, 0, 0]))["fps"] == nil, "overview has no fps")
check(Reply.parse(#"{"type":"welcome","protocol":1,"club":"Testclub","sender":"s1"}"#) == .welcome(club: "Testclub"), "welcome parsed")
check(Reply.parse(#"{"type":"reject","reason":"key"}"#) == .reject(reason: "key"), "reject parsed")
check(Reply.parse(#"{"type":"pong"}"#) == .pong, "pong parsed")
check(newTrackId().count == 12 && newTrackId() != newTrackId(), "track ids are random and short")

// MARK: Time fields: parsing, assignment to decks, position tracking
check(TimeFields.parse("04:18.3")! == (258.3, false), "elapsed format")
check(TimeFields.parse("-03:09:9")! == (189.9, true), "stack/library format with minus and colon")
check(TimeFields.parse("04:03.53") == nil, "track list lengths (two decimals) are not deck times")
check(TimeFields.isEnd("--:--.-"), "end of track shown as --:--.-")
func r(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x, y: y, width: 100, height: 20) }
let decks2 = [DeckInfo(deck: 1, lengthMs: 285_320, title: "Scream & Shout"), DeckInfo(deck: 2, lengthMs: 289_130, title: "I Gotta Feeling")]
// Platter layout (Erweitert): elapsed above remaining, deck 1's platter nearer to deck 2's title.
let platter = [TimeField(rect: r(1123, 145), seconds: 252.0, minus: false), TimeField(rect: r(1123, 164), seconds: 33.3, minus: false),
               TimeField(rect: r(1355, 145), seconds: 19.9, minus: false), TimeField(rect: r(1355, 164), seconds: 269.2, minus: false)]
let pb = TimeFields.bind(fields: platter, texts: [TextSpot(rect: r(1150, 60), text: "I Gotta Feeling")], decks: decks2)
check(pb == [Binding(field: 0, deck: 1, kind: .elapsed), Binding(field: 1, deck: 1, kind: .remaining),
             Binding(field: 2, deck: 2, kind: .elapsed), Binding(field: 3, deck: 2, kind: .remaining)],
      "platter pairs by elapsed + remaining = length (\(pb))")
// Library layout: only remaining, deck 2's title is nearer but to the right of deck 1's field.
let lib = [TimeField(rect: r(897, 80), seconds: 258.3, minus: true), TimeField(rect: r(1950, 80), seconds: 289.1, minus: true)]
let texts = [TextSpot(rect: CGRect(x: 24, y: 62, width: 300, height: 20), text: "Scream & Shout"),
             TextSpot(rect: CGRect(x: 1081, y: 62, width: 300, height: 20), text: "I Gotta Feeling")]
let lb = TimeFields.bind(fields: lib, texts: texts, decks: decks2)
check(lb == [Binding(field: 0, deck: 1, kind: .remaining), Binding(field: 1, deck: 2, kind: .remaining)], "single fields by the title to their left (\(lb))")
// Library layout with 4 decks: the longer title of the row below ends nearer to the field of the upper row.
let decks4 = decks2 + [DeckInfo(deck: 4, lengthMs: 219_040, title: "Sugar (feat. Francesco Yates)")]
let lib4 = [TimeField(rect: CGRect(x: 2490, y: 97, width: 80, height: 25), seconds: 194.1, minus: true),
            TimeField(rect: CGRect(x: 2491, y: 186, width: 80, height: 14), seconds: 142.6, minus: true)]
let lib4texts = [TextSpot(rect: CGRect(x: 1395, y: 72, width: 120, height: 22), text: "I Gotta Feeling"),
                 TextSpot(rect: CGRect(x: 1395, y: 155, width: 280, height: 22), text: "Sugar (feat. Francesco Yates)")]
let lb4 = TimeFields.bind(fields: lib4, texts: lib4texts, decks: decks4)
check(lb4 == [Binding(field: 0, deck: 2, kind: .remaining), Binding(field: 1, deck: 4, kind: .remaining)],
      "the row decides, not the end of a longer title in the next row (\(lb4))")
// Playing backwards past the start: platter shows elapsed -02:00.9 and remaining 05:19.7 for a 198.8 s track.
let rev = [TimeField(rect: r(1365, 158), seconds: 120.9, minus: true), TimeField(rect: r(1373, 176), seconds: 319.7, minus: false)]
let rb = TimeFields.bind(fields: rev, texts: [], decks: [DeckInfo(deck: 2, lengthMs: 198_790, title: nil)])
check(rb == [Binding(field: 0, deck: 2, kind: .elapsed), Binding(field: 1, deck: 2, kind: .remaining)], "negative elapsed before the start pairs with its remaining time (\(rb))")
// Instant double: the same track (same length) on deck 2 (visible) and deck 3 (hidden in the 2-deck view).
let dbl = [DeckInfo(deck: 1, lengthMs: 285_320, title: nil), DeckInfo(deck: 2, lengthMs: 190_190, title: nil), DeckInfo(deck: 3, lengthMs: 190_190, title: nil)]
let dfields = [TimeField(rect: r(1373, 158), seconds: 10.0, minus: false), TimeField(rect: r(1373, 176), seconds: 180.2, minus: false)]
check(TimeFields.bind(fields: dfields, texts: [], decks: dbl).isEmpty, "equal lengths without history: no guessing")
let db = TimeFields.bind(fields: dfields, texts: [], decks: dbl, previous: [(r(1373, 158), 2)])
check(db.map(\.deck) == [2, 2], "equal lengths: the deck seen at that place before wins (\(db))")
let dp = TimeFields.bind(fields: dfields, texts: [], decks: dbl, width: 2582)
check(dp.map(\.deck) == [2, 2], "equal lengths, no history: the right half means deck 2, not deck 3 (\(dp))")
// Stack layout, instant double: the same title on deck 2 and deck 3 decides nothing.
let stackDbl = [DeckInfo(deck: 2, lengthMs: 190_190, title: "GDFR"), DeckInfo(deck: 3, lengthMs: 190_190, title: "GDFR")]
let sdb = TimeFields.bind(fields: [TimeField(rect: r(325, 100), seconds: 108.2, minus: true)],
                          texts: [TextSpot(rect: CGRect(x: 25, y: 92, width: 200, height: 18), text: "GDFR")], decks: stackDbl)
check(sdb.isEmpty, "same title on two decks: no assignment by title (\(sdb))")
// Library, 4 decks, deck 2 = deck 3 (instant double): deck 4's title must not pull the field of the row above.
let lib4dbl = [DeckInfo(deck: 2, lengthMs: 190_190, title: "GDFR"), DeckInfo(deck: 3, lengthMs: 190_190, title: "GDFR"),
               DeckInfo(deck: 4, lengthMs: 219_040, title: "Sugar (feat. Francesco Yates)")]
let l4t = [TextSpot(rect: CGRect(x: 1395, y: 72, width: 60, height: 22), text: "GDFR"),
           TextSpot(rect: CGRect(x: 1395, y: 155, width: 280, height: 22), text: "Sugar (feat. Francesco Yates)")]
let l4b = TimeFields.bind(fields: lib4, texts: l4t, decks: lib4dbl, width: 2582)
check(!l4b.contains(Binding(field: 0, deck: 4, kind: .remaining)), "upper row field is not deck 4 (\(l4b))")
check(l4b.contains(Binding(field: 1, deck: 4, kind: .remaining)), "lower row field is deck 4 (\(l4b))")
let one = TimeFields.bind(fields: [TimeField(rect: r(0, 0), seconds: 287.0, minus: true)], texts: [], decks: decks2)
check(one == [Binding(field: 0, deck: 2, kind: .remaining)], "without titles: the only deck long enough")
check(TimeFields.bind(fields: [TimeField(rect: r(0, 0), seconds: 287.0, minus: false)], texts: [], decks: decks2).isEmpty,
      "single platter field without minus is not assigned (could be elapsed: the deck would run backwards)")
check(TimeFields.bind(fields: [TimeField(rect: r(0, 0), seconds: 20.0, minus: true)], texts: [], decks: decks2).isEmpty,
      "ambiguous field stays unbound (no guessing)")

// Stack layout (measured on Serato 5, 1×): title on the deck's first line, the remaining time 17 px lower on the second.
let stackDecks = [DeckInfo(deck: 1, lengthMs: 285_320, title: "Scream & Shout"),
                  DeckInfo(deck: 4, lengthMs: 219_000, title: "Sugar (feat. Francesco Yates)")]
let stackField = TimeField(rect: CGRect(x: 325, y: 207, width: 60, height: 11), seconds: 155.1, minus: true)
let stackTitle = TextSpot(rect: CGRect(x: 34, y: 190, width: 100, height: 12), text: "Scream & Shout")
check(TimeFields.bind(fields: [stackField], texts: [stackTitle], decks: stackDecks).first?.deck == 1,
      "stack layout: title one line above the time binds the deck")
let farTitle = TextSpot(rect: CGRect(x: 34, y: 150, width: 100, height: 12), text: "Scream & Shout")
check(TimeFields.bind(fields: [TimeField(rect: stackField.rect, seconds: 100, minus: true)], texts: [farTitle], decks: stackDecks).first?.deck != 1,
      "a title three lines up (another deck's row) does not bind")

// Paused deck, the needle cuts the elapsed time ("00:07." is only text); the remaining time 04:37.8 is readable.
let pausedDecks = [DeckInfo(deck: 1, lengthMs: 285_320, title: "Scream & Shout"), DeckInfo(deck: 2, lengthMs: 190_000, title: "GDFR")]
let remainingOnly = TimeField(rect: CGRect(x: 1133, y: 175, width: 70, height: 19), seconds: 277.8, minus: false)
let cut = TextSpot(rect: CGRect(x: 1133, y: 155, width: 60, height: 21), text: "00:07.")
check(TimeFields.bind(fields: [remainingOnly], texts: [cut], decks: pausedDecks, width: 2561).first.map { $0.deck == 1 && $0.kind == .remaining } == true,
      "platter with the elapsed time cut by the needle: the remaining time binds")
check(TimeFields.bind(fields: [remainingOnly], texts: [TextSpot(rect: cut.rect, text: "130.0")], decks: pausedDecks, width: 2561).isEmpty,
      "BPM above is not a cut time (no colon): no binding")
// Both read, but the cut one wrong (00:07.0 instead of 00:07.4: the sum is off): bound field + stacked partner.
let misread = TimeField(rect: CGRect(x: 1133, y: 155, width: 70, height: 21), seconds: 1.0, minus: false)
let both = TimeFields.bind(fields: [misread, remainingOnly], texts: [], decks: pausedDecks, width: 2561)
check(both.count == 2 || both.isEmpty, "stacked fields are bound together or not at all (\(both.map { "\($0.deck)\($0.kind)" }))")

// Track end: elapsed runs on past the length ("03:15.2" for 03:10.19), the remaining time shows "--:--.-".
let endDecks = [DeckInfo(deck: 1, lengthMs: 285_320, title: "Scream & Shout"), DeckInfo(deck: 2, lengthMs: 190_190, title: "GDFR")]
let endField = TimeField(rect: CGRect(x: 1363, y: 158, width: 70, height: 18), seconds: 195.2, minus: false)
let endMark = TextSpot(rect: CGRect(x: 1363, y: 178, width: 70, height: 18), text: "--:--.-")
check(TimeFields.bind(fields: [endField], texts: [endMark], decks: endDecks, width: 2561).first.map { $0.deck == 2 && $0.kind == .elapsed } == true,
      "track end: elapsed past the length above \"--:--.-\" binds to the deck that just ended")
// Seen live: the needle crosses the marker and Vision reads "-*--" (deck 1 at 04:00.6, 03:55 track).
let end1Decks = [DeckInfo(deck: 1, lengthMs: 235_586, title: "Right Here Right Now"), DeckInfo(deck: 2, lengthMs: 190_190, title: "GDFR")]
check(TimeFields.bind(fields: [TimeField(rect: CGRect(x: 1132, y: 157, width: 72, height: 20), seconds: 240.6, minus: false)],
                     texts: [TextSpot(rect: CGRect(x: 1139, y: 180, width: 40, height: 10), text: "-*--")], decks: end1Decks, width: 2561)
        .first.map { $0.deck == 1 && $0.kind == .elapsed } == true,
      "track end: a cut end marker (\"-*--\") under the field also binds the ended deck")
check(TimeFields.bind(fields: [TimeField(rect: CGRect(x: 1132, y: 157, width: 72, height: 20), seconds: 240.6, minus: false)],
                     texts: [TextSpot(rect: CGRect(x: 1139, y: 135, width: 40, height: 10), text: "-*--")], decks: end1Decks, width: 2561).isEmpty,
      "dashes above the field are no end marker")

check(TimeFields.bind(fields: [TimeField(rect: CGRect(x: 1133, y: 158, width: 70, height: 17), seconds: 350.9, minus: false)], texts: [],
                     decks: endDecks, width: 2561).isEmpty,
      "longer than every track, nothing else known: not bound (a misread could land on the wrong deck, QS 3)")

// QS 4, A3: deck 1's remaining time found first, its elapsed time misread (00:01.0, pair does not add up); deck 2
// shorter and free. The misread field sits right above deck 1's remaining time: it is deck 1's, not deck 2's.
let a3Decks = [DeckInfo(deck: 1, lengthMs: 285_320, title: "Scream & Shout"), DeckInfo(deck: 2, lengthMs: 190_190, title: "GDFR")]
let d1r = TimeField(rect: CGRect(x: 1133, y: 177, width: 70, height: 19), seconds: 277.8, minus: false)
let d1e = TimeField(rect: CGRect(x: 1133, y: 155, width: 70, height: 19), seconds: 1.0, minus: false)
let a3 = TimeFields.bind(fields: [d1r, d1e], texts: [TextSpot(rect: d1e.rect, text: "00:01.0"), TextSpot(rect: d1r.rect, text: "04:37.8")],
                         decks: a3Decks, width: 2561)
check(!a3.contains { $0.deck == 2 }, "platter fields found in the other order: both stay with deck 1 (\(a3.map { "\($0.field)->\($0.deck)\($0.kind)" }))")

let t0 = Date()
let tr = PositionTracker(lengthMs: 285_320)
func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
tr.feed(10_000, at: at(0)); tr.feed(10_100, at: at(0.1)); tr.feed(10_200, at: at(0.2))
check(tr.playing && tr.positionMs == 10_200, "advancing readings: playing")
tr.feed(3_861_800, at: at(0.3))
check(tr.positionMs == 10_200, "misread outside the track is ignored")
tr.feed(14_200, at: at(0.4))
check(tr.positionMs == 10_200, "a single far reading is not yet a jump")
tr.feed(14_300, at: at(0.5))
check(tr.positionMs == 14_300, "confirmed by the next reading: jump (cue / needle drop)")
tr.feed(14_400, at: at(0.6)); tr.feed(14_200, at: at(0.7))
check(tr.positionMs == 14_200 && tr.playing, "short step back (½-beat loop) keeps playing")
tr.feed(14_200, at: at(0.8)); tr.feed(14_200, at: at(1.2))
check(tr.playing, "right after a short loop's step back the same value twice: still playing (PAUSE blinked)")
tr.feed(14_200, at: at(2.3))
check(!tr.playing, "same value for 1.6 s: paused")
tr.feed(285_320, at: at(2.4)); tr.feed(285_320, at: at(2.5))
check(tr.positionMs == 285_320, "end of track")
// Seen live: ½-beat loop at 125 BPM (0.24 s), display read every 0.2-0.4 s: 123.4, 123.3, 123.5, 123.4, 123.4 …
let tiny = PositionTracker(lengthMs: 235_586)
var tinyPaused = false
for (k, v) in [123_000, 123_200, 123_400, 123_300, 123_500, 123_400, 123_400, 123_300, 123_500, 123_400, 123_400, 123_300].enumerated() {
    tiny.feed(Int64(v), at: at(Double(k) * 0.4))
    if k > 1 && !tiny.playing { tinyPaused = true }
}
check(!tinyPaused, "½-beat loop: the deck stays playing the whole time")
// Live (19:00:20): ½-beat loop entered while playing, the display shows 52.5, 52.5, 52.6, 52.4, 52.4, 52.5 … (remaining).
let live = PositionTracker(lengthMs: 235_586)
var livePaused = 0
for k in 0...7 { live.feed(121_686 + Int64(k) * 200, at: at(Double(k) * 0.2)) }   // up to 123 086 playing
let liveVals: [Int64] = [123_086, 123_086, 122_986, 123_186, 123_186, 123_086, 123_086, 123_086, 122_986, 123_186, 123_186, 123_086,
                         123_086, 122_986, 123_186, 123_186, 123_186, 123_086, 123_086, 122_986]
for (k, v) in liveVals.enumerated() {
    live.feed(v, at: at(1.6 + Double(k + 1) * 0.27))
    if !live.playing { livePaused += 1 }
}
check(livePaused <= 2, "live ½-beat loop pattern: a pause only at the loop's start, before its first step back (\(livePaused))")
// QS 6, S1: CUE pressed while playing (back 1.5 s to the cue point, deck paused there): a pause after 0.4-0.8 s.
let cueBack = PositionTracker(lengthMs: 235_586)
for k in 0...10 { cueBack.feed(70_000 + Int64(k) * 250, at: at(Double(k) * 0.25)) }   // playing up to 72 500
cueBack.feed(71_000, at: at(2.75)); cueBack.feed(71_000, at: at(3.0)); cueBack.feed(71_000, at: at(3.4)); cueBack.feed(71_000, at: at(3.8))
check(cueBack.positionMs == 71_000 && !cueBack.playing, "CUE back 1.5 s into a pause: paused within 0.8 s, not held as a loop")
// QS 6, K4: a digit partner wins over a loose end marker at the same place.
let k4Decks = [DeckInfo(deck: 1, lengthMs: 235_586, title: "Right Here Right Now")]
let k4Field = TimeField(rect: CGRect(x: 1132, y: 157, width: 72, height: 20), seconds: 100.0, minus: false)
let k4 = TimeFields.bind(fields: [k4Field], texts: [TextSpot(rect: CGRect(x: 1139, y: 180, width: 40, height: 10), text: "-*--"),
                                                   TextSpot(rect: CGRect(x: 1133, y: 178, width: 70, height: 18), text: "02:15.5")],
                         decks: k4Decks, width: 2561)
check(k4.first.map { $0.deck == 1 && $0.kind == .elapsed } == true, "digit partner before an end marker: the field is the elapsed time")
// QS 7: no track or file name may reach a problem report through the log.
check(LogPrivacy.clean("19:30:09  Deck 1: 05 - AC:DC - Thunder.flac geladen, 235 s", home: "/Users/anna") == "19:30:09  Deck 1: Track geladen, 235 s",
      "log: loaded line without the file name")
check(!LogPrivacy.clean("19:31:00  Deck 2: keine Waveform (cannot open 07 - Geheim.m4p: The operation could not be completed)", home: "/Users/anna").contains("Geheim"),
      "log: waveform error of the old wording without the file name")
check(!LogPrivacy.clean("19:31:00  Bildschirm: Aufnahme beendet (/Users/anna/Music/Track Name.mp3)", home: "/Users/anna").contains("Track Name"),
      "log: any audio file name is replaced")
check(LogPrivacy.clean("App in /Users/anna/Desktop", home: "/Users/anna") == "App in ~/Desktop", "log: home folder becomes ~")
check(LogPrivacy.clean("19:30:10  Bildschirm: 4 Zeitfelder, zugeordnet: Deck 1 Laufzeit", home: "/Users/anna") == "19:30:10  Bildschirm: 4 Zeitfelder, zugeordnet: Deck 1 Laufzeit",
      "log: ordinary lines stay as they are")
check(!WaveformError.empty(URL(fileURLWithPath: "/x/Geheim.flac")).kind.contains("Geheim"), "waveform error kind names no file")
let kindLine = "19:31:00  Deck 2: keine Waveform (cannot open the file (NSOSStatusErrorDomain -54))"
check(LogPrivacy.clean(kindLine, home: "/Users/anna") == kindLine, "log: the new waveform error line stays whole (QS 8)")
check(!LogPrivacy.clean("19:31:00  Fehler (/Volumes/USB/Track (Extended Mix).flac)", home: "/Users/anna").contains("Extended"),
      "log: a file name with brackets is replaced (QS 8)")
// QS 5, S4: a plain pause (no loop) is still seen after 0.4 s.
let plain = PositionTracker(lengthMs: 235_586)
for k in 0...5 { plain.feed(50_000 + Int64(k) * 200, at: at(Double(k) * 0.2)) }
plain.feed(51_000, at: at(1.2)); plain.feed(51_000, at: at(1.45))
check(!plain.playing, "plain pause: the same value for 0.45 s is a pause")
// QS 5, S2: a paused deck nudged forward and back is not held on play for 1.5 s.
let nudge = PositionTracker(lengthMs: 235_586)
nudge.feed(80_000, at: at(0)); nudge.feed(80_000, at: at(0.5)); nudge.feed(80_100, at: at(0.7)); nudge.feed(80_000, at: at(0.9))
nudge.feed(80_000, at: at(1.3))
check(!nudge.playing, "nudge of a paused deck: paused again after 0.4 s")
// QS 5, S1: 1-beat loop at 125 BPM (0.48 s), read every 0.35 s: the way back goes over a held jump.
let beat = PositionTracker(lengthMs: 235_586)
var beatPaused = false
var bt = 0.0
for _ in 0..<4 { beat.feed(Int64(100_000 + bt * 1000), at: at(bt)); bt += 0.35 }   // plays into the loop
for k in 0..<20 {
    let inLoop = (bt - 1.4).truncatingRemainder(dividingBy: 0.48)
    beat.feed(101_000 + Int64((inLoop * 10).rounded(.down)) * 100, at: at(bt))   // the display shows tenths
    if k > 2 && !beat.playing { beatPaused = true }
    bt += 0.35
}
check(!beatPaused, "1-beat loop read every 0.35 s: stays playing")
// Playing backwards right after playing forward: paused after the second step back at the latest.
let rev2 = PositionTracker(lengthMs: 235_586)
for k in 0...5 { rev2.feed(60_000 + Int64(k) * 200, at: at(Double(k) * 0.2)) }
for k in 1...4 { rev2.feed(61_000 - Int64(k) * 200, at: at(1.0 + Double(k) * 0.2)) }
check(!rev2.playing, "reverse after forward play: not playing (forwards) for LJ Link")
let ending = PositionTracker(lengthMs: 190_190)
ending.feed(189_500, at: at(0)); ending.feed(189_700, at: at(0.2)); ending.feed(189_900, at: at(0.4))
for k in 1...6 { ending.feed(190_200 + Int64(k) * 200, at: at(0.4 + Double(k) * 0.2)) }   // Serato counts on past the end
ending.feed(195_200, at: at(1.8)); ending.feed(254_000, at: at(2.3)); ending.feed(254_200, at: at(2.5))
check(ending.positionMs == 190_190 && !ending.playing, "track end: held at the length and not playing, however far Serato counts on")
// QS 3: deck at the end on play; misreadings from the middle of the track come in a row (27.2, 29.0, 27.6 …).
let atEnd = PositionTracker(lengthMs: 190_190)
atEnd.feed(189_900, at: at(0)); atEnd.feed(190_190, at: at(0.2)); atEnd.feed(254_000, at: at(0.4)); atEnd.feed(254_000, at: at(0.9))
atEnd.feed(27_200, at: at(1.1)); atEnd.feed(29_000, at: at(1.3)); atEnd.feed(27_600, at: at(1.5)); atEnd.feed(43_900, at: at(1.7))
check(atEnd.positionMs == 190_190 && !atEnd.playing, "at the end: misreadings in a row do not move it (were confirmed before)")
atEnd.feed(283_900, at: at(1.9)); atEnd.feed(283_700, at: at(2.1)); atEnd.feed(283_500, at: at(2.3))
check(atEnd.positionMs == 190_190, "at the end: values running backwards confirm nothing")
// A misreading taken anyway (the old code did): readings past the end that run on like a clock bring it back.
let healed = PositionTracker(lengthMs: 190_190)
healed.feed(27_600, at: at(0)); healed.feed(27_800, at: at(0.2))
for k in 0...6 { healed.feed(254_000 + Int64(k) * 200, at: at(0.4 + Double(k) * 0.2)) }
check(healed.positionMs == 190_190 && !healed.playing, "past the end, counting like a clock for 1 s: the end, wherever the position was")
let digitSlip = PositionTracker(lengthMs: 190_190)
digitSlip.feed(134_000, at: at(0)); digitSlip.feed(134_200, at: at(0.2))
digitSlip.feed(3_735_000, at: at(0.4)); check(digitSlip.hasPendingJump, "past the end while mid-track: Vision is asked")
// With a suspicion the next frame is read by Vision (right), the one after by the digit reader again (wrong) …
for k in 0...7 {
    let t = 0.6 + Double(k) * 0.4
    digitSlip.feed(134_000 + Int64(t * 1000), at: at(t))              // Vision
    digitSlip.feed(3_735_000 + Int64((t + 0.2) * 1000), at: at(t + 0.2))  // digit reader slip
}
check(digitSlip.positionMs.map { $0 < 140_000 } == true, "a right reading in between clears the suspicion of the end")
let fresh = PositionTracker(lengthMs: 190_190)
fresh.feed(559_800, at: at(0))
check(fresh.positionMs == nil, "fresh tracker: one misreading past the end is not taken as the end")
// A real hot cue at the end: the same value twice (paused) is taken.
let cue = PositionTracker(lengthMs: 190_190)
cue.feed(190_190, at: at(0)); cue.feed(190_190, at: at(0.5)); cue.feed(1_900, at: at(0.7)); cue.feed(1_900, at: at(0.9))
check(cue.positionMs == 1_900, "hot cue from the end: taken after one clock-like confirmation")
// Serato's reverse (censor) for 3 s from 60 s: followed, and not reported as playing forwards.
let reverse = PositionTracker(lengthMs: 190_190)
for k in 0...5 { reverse.feed(55_000 + Int64(k) * 200, at: at(Double(k) * 0.2)) }
for k in 1...15 { reverse.feed(56_000 - Int64(k) * 200, at: at(1.0 + Double(k) * 0.2)) }
check(reverse.positionMs.map { abs($0 - 53_000) <= 400 } == true && !reverse.playing, "reverse for 3 s: followed (\(reverse.positionMs ?? -1)), not playing forwards")
for k in 1...6 { reverse.feed(53_000 + Int64(k) * 200, at: at(4.0 + Double(k) * 0.2)) }
check(reverse.playing, "forwards again after reverse: playing")
let middle = PositionTracker(lengthMs: 190_190)
middle.feed(60_000, at: at(0)); middle.feed(60_200, at: at(0.2)); middle.feed(254_000, at: at(0.4)); middle.feed(254_200, at: at(0.6))
check(middle.positionMs == 60_200, "past the length in the middle of a track: a misreading, ignored")
let back = PositionTracker(lengthMs: 198_790)
back.feed(500, at: at(0)); back.feed(-1_000, at: at(0.1)); back.feed(-1_100, at: at(0.2))
check(back.positionMs == 0, "before the start (negative elapsed) is sent as 0, not dropped")
let held = PositionTracker(lengthMs: 200_000)
held.feed(10_000, at: at(0)); held.feed(10_200, at: at(0.2))
held.feed(90_000, at: at(0.4), allowJump: false); held.feed(90_200, at: at(0.6), allowJump: false)
check(held.positionMs == 10_200, "toolbar changed: another deck's time at the old place is not taken over")
held.feed(10_800, at: at(0.8), allowJump: false)
check(held.positionMs == 10_800 && held.playing, "toolbar changed, place still right: keeps running")
held.feed(30_000, at: at(1.0)); held.feed(30_200, at: at(1.2))
check(held.positionMs == 30_200, "after the check, jumps count again")
let pitched = PositionTracker(lengthMs: 300_000)
// Serato at -2 %: 0.98 s of track per second, shown in 0.1 s steps (truncated), read 5 times a second for 8 s.
for i in 0...40 { let t = Double(i) * 0.2; pitched.feed(Int64((50 + t * 0.98) * 10) * 100, at: at(10 + t)) }
check(pitched.speed.map { abs($0 - 0.98) < 0.015 } == true, "speed from 8 s of 0.1 s steps: 0.98 (\(pitched.speed ?? 0))")
pitched.feed(20_000, at: at(18.2)); pitched.feed(20_200, at: at(18.4))
check(pitched.speed == nil, "after a jump the speed is measured anew")

// MARK: Message size limit (LJ Link closes on > 2 MB)
func longWave(_ seconds: Int) -> Waveforms {
    Waveforms(detail: [UInt8](repeating: 1, count: seconds * Waveforms.detailRate * 4), overview: [UInt8](repeating: 1, count: 1600), durationMs: Int64(seconds) * 1000)
}
let fortyMin = Sender.waveformMessages(deck: 1, id: "a", longWave(40 * 60))
check(fortyMin.count == 2 && fortyMin.allSatisfy { $0.json.utf8.count < 2_000_000 }, "40 min track: detail sent, message under 2 MB")
let mix = Sender.waveformMessages(deck: 1, id: "a", longWave(160 * 60))
check(mix.count == 1 && mix[0].json.utf8.count < 2_000_000, "2:40 h mix: overview only, no message over 2 MB")

// MARK: Tags and key notation
check(TrackTags.camelot("Gm") == "6A" && TrackTags.camelot("C") == "8B" && TrackTags.camelot("F#m") == "11A", "musical keys to Camelot")
check(TrackTags.camelot("6A") == "6A" && TrackTags.camelot("12b") == "12B" && TrackTags.camelot("G minor") == "6A", "Camelot stays, words understood")
func vorbisBlock(_ entries: [String]) -> Data {
    var d = Data()
    func le(_ n: Int) { d.append(contentsOf: [UInt8(n & 255), UInt8(n >> 8 & 255), UInt8(n >> 16 & 255), UInt8(n >> 24 & 255)]) }
    le(3); d.append(contentsOf: Array("ven".utf8)); le(entries.count)
    for e in entries { let b = Array(e.utf8); le(b.count); d.append(contentsOf: b) }
    return d
}
let flacFile = tmp.appendingPathComponent("t.flac")
var flacData = Data("fLaC".utf8)
let vb = vorbisBlock(["TITLE=Scream & Shout", "ARTIST=will.i.am", "BPM=130", "INITIALKEY=Gm", "SERATO_OVERVIEW=xyz"])
flacData.append(contentsOf: [0x00, 0, 0, 2, 0xAA, 0xBB])                         // a 2-byte block of another type
flacData.append(contentsOf: [0x84, UInt8(vb.count >> 16 & 255), UInt8(vb.count >> 8 & 255), UInt8(vb.count & 255)])
flacData.append(vb)
try! flacData.write(to: flacFile)
let tg = TrackTags.read(flacFile)
check(tg == TrackTags(title: "Scream & Shout", artist: "will.i.am", bpm: 130, key: "6A"), "FLAC Vorbis tags: title, artist, BPM, key (\(tg))")

// MARK: suite chat (LJ Link docs/suite-chat.md)

final class Wire: SuiteChat.Out {
    var sent: [(String, TimeInterval)] = []
    func send(_ json: String, delay: TimeInterval) { sent.append((json, delay)) }
    func deliver(to c: SuiteChat, now: TimeInterval) { for (j, _) in sent { c.receive(Data(j.utf8), now: now) }; sent.removeAll() }
    func type(_ i: Int) -> String {
        ((try? JSONSerialization.jsonObject(with: Data(sent[i].0.utf8))) as? [String: Any])?["t"] as? String ?? ""
    }
}
let wa = Wire(), wb = Wire()
let ca = SuiteChat(app: "LJL Link", out: wa, peer: "aaaaaaaa01")
let cb = SuiteChat(app: "LJ Link", out: wb, peer: "bbbbbbbb02")
ca.setOn(true, now: 0); cb.setOn(true, now: 0)
check(wa.type(0) == "here" && wa.type(1) == "history?", "chat: joining says here and asks for the history")
check(!ca.post("Hallo", now: 1), "chat: no message without a nickname (the app asks first)")
ca.setNick("DJ Anna", now: 1)
wa.sent.removeAll()
check(ca.post("Drop in 30 s", now: 2), "chat: message with a nickname")
check(wa.sent.count == 2 && wa.sent[1].1 == 0.3, "chat: every message sent twice")
wa.deliver(to: cb, now: 2)
check(cb.snapshot.lines.count == 1 && cb.snapshot.lines[0].nick == "DJ Anna" && cb.snapshot.lines[0].app == "LJL Link",
      "chat: the second copy is dropped, nickname and program shown")
check(cb.snapshot.members == [SuiteChat.Member(nick: "DJ Anna", app: "LJL Link")], "chat: who is in the room")
ca.setProfile("DJ David", "DJ Booth", now: 2.5); wa.deliver(to: cb, now: 2.5)
check(cb.snapshot.members.first?.where_ == "DJ Booth", "chat: position of a member")
check(ca.post("Feuer an der Bar!", urgent: true, now: 2.6) && wa.sent.last?.0.contains(#""urgent":true"#) == true, "chat: EMERGENCY marked")
wa.deliver(to: cb, now: 2.6)
check(cb.snapshot.lines.last?.urgent == true && cb.snapshot.lines.last?.where_ == "DJ Booth", "chat: EMERGENCY arrives as urgent, with position")
check(SuiteChat.who("DJ David", "DJ Booth", "LJL Link") == "DJ David (DJ Booth) · LJL Link", "chat: name (position) · program")
ca.receive(Data(#"{"suite":"chat","v":1,"t":"msg","peer":"ffffffff06","id":"ffffffff06-1","text":"alt","urgent":true,"old":true}"#.utf8), now: 2.7)
check(ca.snapshot.lines.last?.urgent == false, "chat: an old EMERGENCY from the history is no pop-up")
cb.tick(now: 20)
check(cb.snapshot.members.isEmpty, "chat: silent for 15 s, gone")
// Java's JSON from LJ Link (other key order, "at" in ms) is read the same.
ca.receive(Data(#"{"suite":"chat","v":1,"t":"msg","peer":"cccccccc03","id":"cccccccc03-1","nick":"Phil","app":"LJ Link","text":"Mehr\nNebel? \u202E","at":1794685866935}"#.utf8), now: 3)
check(ca.snapshot.lines.last?.text == "Mehr Nebel?", "chat: line breaks become spaces, direction marks go")
check(SuiteChat.clean(String(repeating: "x", count: 900), max: SuiteChat.maxText).count == 500, "chat: 500 characters")
for i in 0..<15 {
    ca.receive(Data(#"{"suite":"chat","v":1,"t":"msg","peer":"dddddddd04","id":"dddddddd04-\#(i)","text":"spam"}"#.utf8), now: 4 + Double(i) * 0.01)
}
check(ca.snapshot.lines.filter { $0.text == "spam" }.count == 10, "chat: at most 10 per peer in 10 s")
let before = ca.snapshot.lines.count
ca.receive(Data(#"{"suite":"chat","v":1,"t":"msg","peer":"aaaaaaaa01","id":"aaaaaaaa01-9","text":"echo"}"#.utf8), now: 30)
ca.receive(Data(#"{"suite":"chat","v":2,"t":"msg","peer":"eeeeeeee05","id":"e-1","text":"v2"}"#.utf8), now: 30)
ca.receive(Data("kein json".utf8), now: 30)
check(ca.snapshot.lines.count == before, "chat: own echo, other versions and broken data dropped")
check(!ca.diagnostics.contains("Anna") && !ca.diagnostics.contains("Drop"), "chat: problem report names no nickname, no text")
ca.setOn(false, now: 31)
check(wa.type(wa.sent.count - 1) == "bye" && !ca.post("x", now: 32), "chat: off says bye and sends nothing more")

cq0: do {
    let w0 = Wire(); let c0 = SuiteChat(app: "LJL Link", out: w0, peer: "kkkkkkkk01"); c0.setOn(true, now: 0)
    c0.receive(Data(#"{"suite":"chat","v":1,"t":"msg","peer":"llllllll02","id":"mmmmmmmm03-1","text":"falsch"}"#.utf8), now: 1)
    check(c0.snapshot.lines.isEmpty, "chat: a message whose id is not the sender's own is dropped")
}
cqOld: do {
    let w1 = Wire(); let c1 = SuiteChat(app: "LJL Link", out: w1, peer: "oooooooo01"); c1.setOn(true, now: 0)
    c1.receive(Data(#"{"suite":"chat","v":1,"t":"msg","peer":"gonegone02","id":"gonegone02-1","nick":"Weg","app":"VJ-Link","text":"alt","old":true}"#.utf8), now: 20)
    check(c1.snapshot.lines.count == 1 && c1.snapshot.members.isEmpty, "chat: a history message does not bring its (gone) sender back into the room")
    for i in 2..<20 {
        c1.receive(Data(#"{"suite":"chat","v":1,"t":"msg","peer":"gonegone\#(String(format: "%02d", i))","id":"gonegone\#(String(format: "%02d", i))-1","text":"alt","old":true}"#.utf8), now: 21)
    }
    check(c1.snapshot.lines.count == 10, "chat: outside the own window, history from strangers 10 in 10 s together")
}
cqAgain: do {
    let w2 = Wire(); let c2 = SuiteChat(app: "LJL Link", out: w2, peer: "aaaa2222bb"); c2.setOn(true, now: 0)
    w2.sent.removeAll(); c2.tick(now: 13)
    check(w2.sent.contains { $0.0.contains(#""t":"history?""#) }, "chat: no history 12 s after joining: asks once more")
    w2.sent.removeAll(); c2.tick(now: 30)
    check(!w2.sent.contains { $0.0.contains(#""t":"history?""#) }, "chat: and only once")
    c2.receive(Data(#"{"suite":"chat","v":1,"t":"msg","peer":"cccc3333dd","id":"cccc3333dd-1","text":"a\u2028b\u061Cc","old":true}"#.utf8), now: 31)
    check(c2.snapshot.lines.last?.text == "a bc" && c2.snapshot.lines.last?.old == true, "chat: U+2028 a space, U+061C removed; history marked old")
    c2.setOn(false, now: 32)
    check(c2.snapshot.lines.isEmpty, "chat: switched off forgets the messages")
}
cqTypes: do {
    let w3 = Wire(); let c3 = SuiteChat(app: "LJL Link", out: w3, peer: "tttt4444uu"); c3.setOn(true, now: 0)
    c3.receive(Data(#"{"suite":"chat","v":1,"t":"msg","peer":"vvvv5555ww","id":"vvvv5555ww-1","text":"eins","urgent":1}"#.utf8), now: 1)
    c3.receive(Data(#"{"suite":"chat","v":1,"t":"msg","peer":"vvvv5555ww","id":"vvvv5555ww-2","text":"zwei","urgent":"true"}"#.utf8), now: 2)
    check(c3.snapshot.lines.allSatisfy { !$0.urgent }, "chat: urgent only as a real true (not 1, not \"true\")")
    c3.receive(Data(#"{"suite":"chat","v":1,"t":"msg","peer":"vvvv5555ww","id":"vvvv5555ww-3","text":"  a  b  ","at":5}"#.utf8), now: 3)
    check(c3.snapshot.lines.last?.text == "a  b", "chat: trimmed at both ends, inner spaces kept (as in LJ Link and VJ-Link)")
    check(abs(c3.snapshot.lines.last!.at.timeIntervalSince1970 - 3) < 0.001, "chat: a live message is placed by its arrival, not by the sender's clock")
    c3.receive(Data("{\"suite\":\"chat\",\"v\":1,\"t\":\"msg\",\"peer\":\"vvvv5555ww\\n\",\"id\":\"vvvv5555ww\\n-4\",\"text\":\"x\"}".utf8), now: 4)
    check(c3.snapshot.lines.count == 3, "chat: a peer with a trailing line break is no valid peer")
    c3.setNick("A", now: 5); w3.sent.removeAll(); c3.post("hi", now: 6)
    let sentId = ((try? JSONSerialization.jsonObject(with: Data(w3.sent[0].0.utf8))) as? [String: Any])?["id"] as? String ?? ""
    check(sentId.hasPrefix("tttt4444uu-1") && sentId.count == "tttt4444uu-1".count + 8, "chat: own ids are peer-counter plus 8 random characters")
}
cqKann: do {
    let w4 = Wire(); let c4 = SuiteChat(app: "LJL Link", out: w4, peer: "kann4444aa"); c4.setOn(true, now: 0)
    c4.receive(Data(#"{"suite":"chat","v":true,"t":"msg","peer":"kann5555bb","id":"kann5555bb-1","text":"x"}"#.utf8), now: 1)
    check(c4.snapshot.lines.isEmpty, "chat: v must be the number 1, not true")
    c4.receive(Data(#"{"suite":"chat","v":1,"t":"msg","peer":"kann5555bb","id":"kann5555bb-2","text":"a\n\n\nb"}"#.utf8), now: 2)
    check(c4.snapshot.lines.last?.text == "a b", "chat: a run of line breaks becomes one space")
}
// QS 10, MUSS 1: an absurd time must not crash anything (it did when sent on as history).
let wq = Wire()
let cq = SuiteChat(app: "LJL Link", out: wq, peer: "qqqqqqqq01")
cq.setOn(true, now: 0)
cq.receive(Data(#"{"suite":"chat","v":1,"t":"msg","peer":"rrrrrrrr02","id":"rrrrrrrr02-1","text":"x","at":1e300}"#.utf8), now: 100)
cq.receive(Data(#"{"suite":"chat","v":1,"t":"msg","peer":"rrrrrrrr02","id":"rrrrrrrr02-2","text":"y","at":-5}"#.utf8), now: 100)
wq.sent.removeAll()
cq.receive(Data(#"{"suite":"chat","v":1,"t":"history?","peer":"ssssssss03"}"#.utf8), now: 101)
check(wq.sent.count == 2 && cq.snapshot.lines.allSatisfy { abs($0.at.timeIntervalSince1970 - 100) < 1 },
      "chat: an absurd 'at' becomes the receiver's own time; the history answer does not crash")
// QS 10, MUSS 2: history? answered at most once in 10 s, from anyone.
wq.sent.removeAll()
for i in 0..<50 { cq.receive(Data(#"{"suite":"chat","v":1,"t":"history?","peer":"tttttt\#(String(format: "%04d", i))"}"#.utf8), now: 102 + Double(i) * 0.1) }
check(wq.sent.isEmpty, "chat: a flood of history? questions gets no answer within 10 s")
cq.tick(now: 125); wq.sent.removeAll() // the 50 questioners (the most peers there may be) have gone silent
cq.receive(Data(#"{"suite":"chat","v":1,"t":"history?","peer":"uuuuuuuu04"}"#.utf8), now: 125)
check(wq.sent.count == 2, "chat: after 10 s the next one is answered again")
let empty = SuiteChat(app: "LJL Link", out: wq, peer: "vvvvvvvv05"); empty.setOn(true, now: 0); wq.sent.removeAll()
empty.receive(Data(#"{"suite":"chat","v":1,"t":"history?","peer":"wwwwwwww06"}"#.utf8), now: 1)
check(wq.sent.isEmpty, "chat: without messages no answer at all")
// QS 10, SOLLTE 5: at most 3 pop-ups per peer in 60 s.
cq.tick(now: 199)
for i in 0..<6 {
    cq.receive(Data(#"{"suite":"chat","v":1,"t":"msg","peer":"xxxxxxxx07","id":"xxxxxxxx07-\#(i)","text":"Notfall \#(i)","urgent":true}"#.utf8), now: 200 + Double(i))
}
check(cq.snapshot.lines.filter { $0.urgent }.count == 3 && cq.snapshot.lines.filter { $0.text.hasPrefix("Notfall") }.count == 6,
      "chat: 3 EMERGENCY pop-ups per peer and minute, the rest as normal messages")

// Real multicast on this Mac: two rooms in one process hear each other (loopback), like LJ Link and LJL Link.
let n1 = SuiteChat.Net(port: 47699), n2 = SuiteChat.Net(port: 47699) // not the real room
let r1 = SuiteChat(app: "LJL Link", out: n1), r2 = SuiteChat(app: "LJ Link", out: n2)
if n1.start(r1) && n2.start(r2) {
    r1.setNick("Test", now: Date().timeIntervalSince1970); r1.setOn(true); r2.setOn(true)
    r1.post("Hallo über das Netz")
    var got = false
    for _ in 0..<40 where !got {
        Thread.sleep(forTimeInterval: 0.05)
        got = r2.snapshot.lines.contains { $0.text == "Hallo über das Netz" }
    }
    check(got, "chat: a message goes over real multicast between two programs on this Mac")
    r1.setOn(false); r2.setOn(false)
} else {
    check(false, "chat: multicast port \(SuiteChat.port) could not be opened")
}

try? FileManager.default.removeItem(at: tmp)
print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)

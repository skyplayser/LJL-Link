// Development front end of LJL Link (formerly "LJ Link Sender"): the same core from the command line.
//   ljlink-sender wave <audio file> [preview.png]   build the waveforms of one file and draw a preview
//   ljlink-sender watch [preview dir]               follow Serato's log; for every loaded track build the waveforms
// The real app (menu bar, connection to LJ Link) comes later; this is for checking the building blocks with real files.
import AppKit
import Foundation
import SenderCore

func preview(_ w: Waveforms, to path: String) {
    // Overview on top (whole track), first 20 s of the detail below; low = blue, mid = amber, high = white,
    // painted back to front like LJ Link's three-band style.
    let width = 1200, ovH = 120, dtH = 160, height = ovH + dtH + 10
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(calibratedWhite: 0.06, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let colors = [NSColor(calibratedRed: 0.13, green: 0.40, blue: 1, alpha: 1),
                  NSColor(calibratedRed: 1, green: 0.65, blue: 0.13, alpha: 1),
                  NSColor(calibratedWhite: 0.95, alpha: 1)]
    func draw(_ data: [UInt8], entries: Int, y0: Int, h: Int) {
        guard entries > 0 else { return }
        for x in 0..<width {
            let e = min(entries - 1, x * entries / width)
            for band in 0..<3 {
                let v = CGFloat(data[e * 4 + band]) / 255 * CGFloat(h) / 2
                colors[band].setFill()
                NSRect(x: CGFloat(x), y: CGFloat(y0) + CGFloat(h) / 2 - v, width: 1, height: 2 * v).fill()
            }
        }
    }
    draw(w.overview, entries: w.overview.count / 4, y0: dtH + 10, h: ovH)
    let first = Array(w.detail.prefix(20 * Waveforms.detailRate * 4))
    draw(first, entries: first.count / 4, y0: 0, h: dtH)
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

func build(_ url: URL, previewPath: String?) {
    let tags = TrackTags.read(url)
    print("  tags: title=\(tags.title ?? "-") artist=\(tags.artist ?? "-") bpm=\(tags.bpm.map { String($0) } ?? "-") key=\(tags.key ?? "-")")
    let t0 = Date()
    do {
        let w = try WaveformBuilder.build(from: url)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("  waveforms: \(w.detailFrames) detail entries (\(w.durationMs / 1000) s), \(w.overview.count / 4) overview, \(ms) ms, \(w.detail.count / 1024) KB")
        if let p = previewPath { preview(w, to: p); print("  preview: \(p)") }
    } catch {
        print("  waveforms failed: \(error)")
    }
}

setvbuf(stdout, nil, _IOLBF, 0)  // line by line, also when written to a file
let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "wave" where args.count > 2:
    build(URL(fileURLWithPath: args[2]), previewPath: args.count > 3 ? args[3] : nil)
case "digits" where args.count > 2:
    // Digit reader on a series of captures of the same layout: per field it learns from Vision on each capture and
    // then reads every capture alone; prints how often it agrees with Vision.
    let imgs = args.dropFirst(2).compactMap { NSImage(contentsOfFile: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    guard let first = imgs.first else { exit(1) }
    let (fields, _) = ScreenTimeReader.findFields(first)
    for f in fields {
        let r = f.rect
        let padR = r.insetBy(dx: -r.height * 0.6, dy: -r.height * 0.25).integral
        let reader = DigitReader()
        var vis: [String?] = []
        for img in imgs {
            guard let pad = img.cropping(to: padR),
                  let v = ScreenTimeReader.readCropWithBoxes(pad, textHeight: r.height) else { vis.append(nil); continue }
            vis.append(v.text)
            reader.learn(pad, text: v.text, line: v.line)
        }
        var agree = 0, own = 0, wrong: [String] = []
        for (img, v) in zip(imgs, vis) {
            guard let pad = img.cropping(to: padR), let s = reader.read(pad) else { continue }
            own += 1
            if s == v?.filter({ !$0.isWhitespace }) { agree += 1 } else { wrong.append("\(s)≠\(v ?? "-")") }
        }
        print("field @\(Int(r.minX)),\(Int(r.minY)) h\(Int(r.height)): digits learned \(reader.learnedDigits), read alone \(own)/\(imgs.count), agrees with Vision \(agree)" + (wrong.isEmpty ? "" : " wrong: \(wrong.prefix(4))"))
    }
case "fields" where args.count > 2:
    // Calibration on saved window captures: which time fields are found and how they are assigned to the decks
    // currently in Serato's log.
    // --decks "1=285320:Title;2=..." overrides the decks from the log (for captures taken with other tracks loaded).
    var paths = Array(args.dropFirst(2))
    var given: [DeckInfo]?
    if let i = paths.firstIndex(of: "--decks"), i + 1 < paths.count {
        given = paths[i + 1].split(separator: ";").compactMap { part in
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, let d = Int(kv[0]) else { return nil }
            let lt = kv[1].split(separator: ":", maxSplits: 1)
            return DeckInfo(deck: d, lengthMs: Int64(lt[0]) ?? 0, title: lt.count > 1 ? String(lt[1]) : nil)
        }
        paths.removeSubrange(i...(i + 1))
    }
    let decks: [DeckInfo] = given ?? SeratoLog.seratoFolder().map { f in
        SeratoLogFollower(seratoFolder: f).current().map {
            DeckInfo(deck: $0.deck, lengthMs: $0.lengthMs, title: TrackTags.read($0.file).title)
        }
    } ?? []
    print("decks: " + decks.map { "\($0.deck)=\($0.lengthMs / 1000)s \($0.title ?? "-")" }.joined(separator: ", "))
    for path in paths {
        guard let img = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        let t0 = Date()
        let (fields, texts) = ScreenTimeReader.findFields(img)
        let binds = TimeFields.bind(fields: fields, texts: texts, decks: decks)
        print("\((path as NSString).lastPathComponent): \(fields.count) fields in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        if ProcessInfo.processInfo.environment["LJL_DEBUG_TEXTS"] == "1" {
            for t in texts where t.text.contains(":") || t.text.contains("--") {
                print(String(format: "  text \"%@\" at %4d,%4d h%2d", t.text, Int(t.rect.minX), Int(t.rect.minY), Int(t.rect.height)))
            }
        }
        for (i, f) in fields.enumerated() {
            let b = binds.first { $0.field == i }
            print(String(format: "  %@%5.1f s at %4d,%4d h%2d -> %@", f.minus ? "-" : " ", f.seconds, Int(f.rect.minX), Int(f.rect.minY),
                         Int(f.rect.height), b.map { "deck \($0.deck) \($0.kind.rawValue)" } ?? "unbound"))
        }
    }
case "watch":
    guard let folder = SeratoLog.seratoFolder() else { print("no Serato folder in ~/Music/_Serato_"); exit(1) }
    let dir = args.count > 2 ? args[2] : nil
    let follower = SeratoLogFollower(seratoFolder: folder)
    for l in follower.current() { print("already loaded: deck \(l.deck), \(l.lengthMs / 1000) s, \(l.file.lastPathComponent)") }
    print("watching Serato's log (Ctrl-C to stop)")
    while true {
        for l in follower.poll() {
            print("\(Date()): deck \(l.deck) loaded \(l.file.lastPathComponent) (\(l.lengthMs / 1000) s)")
            build(l.file, previewPath: dir.map { "\($0)/deck\(l.deck).png" })
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
case "run":
    // ljlink-sender run [--club club.json] [--host h --port p --key k] [--names]; without club.json: Bonjour and approval
    func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    var config: ClubConfig?
    if let path = opt("--club"), let d = FileManager.default.contents(atPath: path) {
        config = try? JSONDecoder().decode(ClubConfig.self, from: d)
    } else if let host = opt("--host"), let key = opt("--key") {
        config = ClubConfig(version: 1, club: "Test", hosts: [host], port: Int(opt("--port") ?? "8080") ?? 8080, key: key)
    } else {
        config = ClubConfig.load()
    }
    if config == nil { print("no club.json: looking for LJ Link by Bonjour, approval in the booth") }
    guard let folder = SeratoLog.seratoFolder() else { print("no Serato folder in ~/Music/_Serato_"); exit(1) }
    let sender = Sender(config: config, seratoFolder: folder, names: args.contains("--names"),
                        computerName: Host.current().localizedName ?? "Mac", software: "Serato DJ Pro",
                        appVersion: "0.1.0-dev", readPositions: !args.contains("--no-positions"),
                        onState: { print("\(Date()): \($0)") }, log: { print("\(Date()): \($0)") })
    sender.start()
    signal(SIGINT) { _ in exit(0) }
    // Development: `kill -USR1 <pid>` switches track titles on/off, `kill -TERM` quits with bye.
    var namesOn = args.contains("--names")
    signal(SIGUSR1, SIG_IGN)
    let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    usr1.setEventHandler { namesOn.toggle(); print("\(Date()): Tracknamen \(namesOn ? "an" : "aus")"); sender.setNames(namesOn) }
    usr1.resume()
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler { sender.stop(); exit(0) }
    term.resume()
    dispatchMain()
default:
    print("usage: ljlink-sender wave <file> [preview.png] | watch [preview dir] | run [--club f | --host h --port p --key k] [--names]")
    exit(1)
}

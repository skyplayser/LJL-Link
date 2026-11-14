import AppKit
import SenderCore
import SwiftUI

// "Report a problem" like in LJ Link: a description and/or a rating, optional diagnostic data, then mail, file or
// clipboard. Nothing is sent by itself. The diagnostic data names no track, no artist, no file and no club key.

enum Report {
    static let mail = "fehlermelden@nextphilm.de"
    /// Mail programs cut long mailto links (Windows and Outlook at about 2000 characters, LJ Link ADR-034).
    static let mailtoMax = 2000

    static func fileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return "LJL-Link-report-\(f.string(from: Date())).txt"
    }


    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static var translated: Bool {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &v, &size, nil, 0) == 0 && v == 1
    }

    static var seratoVersion: String? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.serato.seratodj").first
                ?? NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Serato DJ Pro" }),
              let url = app.bundleURL, let b = Bundle(url: url) else { return nil }
        return b.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}

extension Model {
    /// The diagnostic data, in English like LJ Link's (read by support). Most important first.
    func diagnostics() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func tidy(_ s: String) -> String { s.replacingOccurrences(of: home, with: "~") }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = Report.translated ? "x86_64 (Rosetta)" : "x86_64"
        #endif
        let withPos = decks.filter { $0.positionMs != nil }.count
        let linkState: String = {
            switch link {
            case .connected: return "connected"
            case .rejected: return "refused"
            case .waiting: return "not reachable"
            case .connecting: return "connecting"
            }
        }()
        let screenState: String = {
            switch screen {
            case .reading: return "reading Serato's time display"
            case .denied: return "screen recording not allowed"
            case .waiting: return "Serato window not found"
            case .off: return "not started"
            }
        }()
        var out: [String] = []
        out.append("== Summary ==")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        out.append("LJL Link \(Model.version) (Alpha), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(arch)")
        out.append("Phase: \(phase == .running ? "sending" : phase == .askNames ? "waiting for the track-name answer" : "no club.json")")
        if phase == .running {
            out.append("LJ Link: \(linkState)")
            out.append("Position: \(screenState)")
            out.append("Decks: \(decks.count) loaded, \(withPos) with position")
            out.append("Track names: \(names ? "sent" : "not sent")")
            out.append(room.diagnostics + " (content not included)")
        }
        out.append("")
        out.append("== LJL Link ==")
        out.append("Version \(Model.version), \(arch), language \(L.german ? "de" : "en")")
        out.append("Mac: \(Report.sysctl("hw.model") ?? "?"), \(ProcessInfo.processInfo.processorCount) cores, \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
        out.append("App: \(tidy(Bundle.main.bundlePath))")
        if let c = club {
            out.append("Club: \(c.club), hosts \(c.hosts.joined(separator: ", ")), port \(c.port), key present (not shown)")
        } else {
            out.append("Club: no club.json")
        }
        out.append("Connection: \(linkText)")
        out.append("Serato: \(seratoFound ? "folder found" : "folder not found"), \(Report.seratoVersion.map { "Serato DJ Pro \($0) running" } ?? "not running")")
        out.append("Screen: \(screenState)")
        out.append("")
        out.append("== Decks ==")
        if decks.isEmpty { out.append("none") }
        for d in decks {
            // No title, artist or file: only what LJ Link would show without track names.
            let pos = d.positionMs.map { "\(timeText($0)) \(d.playing ? "playing" : "paused")" } ?? "no position"
            out.append("Deck \(d.deck): length \(timeText(d.lengthMs)), \(pos), waveform \(d.waveform ? "ready" : "building")"
                       + (d.bpm.map { String(format: ", %.1f BPM", $0) } ?? "") + (d.key.map { ", key \($0)" } ?? ""))
        }
        out.append("")
        out.append("== Last log lines ==")
        out.append(contentsOf: log.suffix(150).map { LogPrivacy.clean($0, home: home) })
        return out.joined(separator: "\n")
    }
}

struct ReportSheet: View {
    @EnvironmentObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var stars = 0
    @State private var withDiag = true
    @State private var diag = ""
    @State private var status = ""
    @State private var attachNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("Fehler melden oder Wunsch äußern", "Report a problem or request a feature")).font(.title3.bold())
            HStack(spacing: 8) {
                Text(L.t("Wie gefällt dir LJL Link? (optional)", "How do you like LJL Link? (optional)"))
                    .font(.system(size: 12)).foregroundStyle(Palette.dim)
                ForEach(1...5, id: \.self) { n in
                    Button { stars = stars == n ? 0 : n } label: {
                        Image(systemName: n <= stars ? "star.fill" : "star").foregroundStyle(n <= stars ? Palette.warn : Palette.dim)
                    }
                    .buttonStyle(.plain)
                    .help(L.t("\(n) von 5 Sternen", "\(n) of 5 stars"))
                }
            }
            Text(L.t("Was ist passiert, oder was wünschst du dir?", "What happened, or what would you like?"))
                .font(.system(size: 12, weight: .semibold))
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(L.t("Beispiel: Deck 2 zeigt in LJ Link „keine Position“, obwohl der Track läuft. Serato 4.0, Layout „Stapel“.",
                                 "Example: deck 2 shows “no position” in LJ Link although the track is playing. Serato 4.0, layout “Stack”."))
                            .font(.system(size: 13)).foregroundStyle(Palette.dim.opacity(0.7)).padding(11).allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
            Toggle(L.t("Diagnosedaten anhängen", "Include diagnostic data"), isOn: $withDiag)
            Text(L.t("Version von App, macOS und Serato, Verbindung zu LJ Link, Zustand der Decks (Länge, Position, Waveform) und die letzten Protokollzeilen. Keine Tracktitel, keine Artists, keine Dateinamen, kein Club-Schlüssel.",
                     "Versions of the app, macOS and Serato, the connection to LJ Link, the state of the decks (length, position, waveform) and the last log lines. No track titles, no artists, no file names, no club key."))
                .font(.system(size: 11)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(L.t("Diagnosedaten ansehen", "Show diagnostic data")) {
                ScrollView {
                    Text(diag).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.dim)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 140)
            }
            .font(.system(size: 12))
            if let attachNote {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("Bitte die Datei selbst an die Mail hängen", "Please attach the file to the mail yourself")).font(.system(size: 12, weight: .bold))
                    Text(attachNote).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.warn.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.warn.opacity(0.6)))
            }
            HStack(spacing: 8) {
                Button(L.t("Per E-Mail senden", "Send by email")) { sendMail() }.buttonStyle(.borderedProminent).tint(Palette.accent)
                Button(L.t("Als Datei sichern …", "Save as file …")) { saveFile() }
                Button(L.t("Kopieren", "Copy")) { copy() }
                Spacer()
                Button(L.t("Schließen", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if !status.isEmpty {
                Text(status).font(.system(size: 12)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Palette.bg)
        .onAppear { diag = model.diagnostics() }
    }

    private var ratingLine: String { stars > 0 ? L.t("Bewertung: \(stars) von 5 Sternen", "Rating: \(stars) of 5 stars") : "" }

    private var head: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if stars > 0 { parts.append(ratingLine) }
        if !t.isEmpty { parts.append(t) } else if stars == 0 { parts.append(L.t("(keine Beschreibung)", "(no description)")) }
        return parts.joined(separator: "\n\n")
    }

    private var full: String { withDiag && !diag.isEmpty ? head + "\n\n" + diag : head }

    private var subject: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "LJL Link: " + String((t.isEmpty ? ratingLine : t.components(separatedBy: .newlines)[0]).prefix(80))
    }

    /// A report needs a description or a rating.
    private func ready() -> Bool {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || stars > 0 { return true }
        status = L.t("Bitte erst das Problem oder den Wunsch beschreiben, oder eine Bewertung wählen.",
                     "Please describe the problem or your wish first, or choose a rating.")
        return false
    }

    /// Saves the diagnostic report into the downloads folder (as LJ Link's browser does) and returns the file.
    private func writeToDownloads() -> URL? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(Report.fileName())
        do { try full.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }

    private func sendMail() {
        guard ready() else { return }
        attachNote = nil
        // Apple Mail (and other mail apps that support it) take the report file as a real attachment.
        if withDiag, let service = NSSharingService(named: .composeEmail) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(Report.fileName())
            if (try? full.write(to: file, atomically: true, encoding: .utf8)) != nil {
                service.recipients = [Report.mail]
                service.subject = subject
                let items: [Any] = [head + "\n\n" + L.t("Die Diagnosedaten hängen als Datei an.", "The diagnostic data is attached as a file."), file]
                if service.canPerform(withItems: items) {
                    service.perform(withItems: items)
                    status = L.t("Dein Mailprogramm öffnet sich mit der Meldung an \(Report.mail), die Diagnosedaten hängen an. Wenn sich nichts öffnet (z. B. kein Mailkonto eingerichtet): „Als Datei sichern …“ und die Datei an \(Report.mail) schicken.",
                                 "Your mail program opens with the report to \(Report.mail), the diagnostic data attached. If nothing opens (e.g. no mail account set up): “Save as file …” and send the file to \(Report.mail).")
                    return
                }
            }
        }
        // Otherwise a mailto link: short enough for every mail program; a longer report goes into a file to attach.
        var body = full
        if mailto(body).count > Report.mailtoMax, withDiag, let file = writeToDownloads() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(diag, forType: .string)
            body = L.t("BITTE ANHÄNGEN: die Datei \(file.lastPathComponent) aus deinem Download-Ordner. Das Mailprogramm hängt sie nicht selbst an.",
                       "PLEASE ATTACH: the file \(file.lastPathComponent) from your downloads folder. The mail program does not attach it by itself.")
                + "\n\n" + head
            var summary = diag.components(separatedBy: "\n\n").first ?? ""
            while mailto(body + "\n\n" + summary).count > Report.mailtoMax, !summary.isEmpty {
                summary = summary.components(separatedBy: "\n").dropLast().joined(separator: "\n")
            }
            if summary.components(separatedBy: "\n").count > 1 { body += "\n\n" + summary }
            attachNote = L.t("Die Diagnosedaten liegen jetzt in deinem Download-Ordner: \(file.lastPathComponent). Häng diese Datei an die Mail, bevor du sie sendest. Sie sind auch in der Zwischenablage, falls die Datei fehlt (⌘V in die Mail).",
                             "The diagnostic data is now in your downloads folder: \(file.lastPathComponent). Attach this file to the mail before you send it. It is also in the clipboard if the file is missing (⌘V into the mail).")
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
        if let url = URL(string: mailto(body)) { NSWorkspace.shared.open(url) }
        status = L.t("Dein Mailprogramm öffnet sich mit der Meldung an \(Report.mail). Wenn sich nichts öffnet, schick sie von Hand an diese Adresse.",
                     "Your mail program opens with the report to \(Report.mail). If nothing opens, send it by hand to that address.")
    }

    private func mailto(_ body: String) -> String {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = Report.mail
        c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        // URLComponents leaves "+" as it is; some mail programs read it as a space (LJ Link encodes it, too).
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url?.absoluteString ?? "mailto:\(Report.mail)"
    }

    private func saveFile() {
        guard ready() else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = Report.fileName()
        p.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        p.allowedContentTypes = [.plainText]
        if p.runModal() == .OK, let url = p.url {
            if (try? full.write(to: url, atomically: true, encoding: .utf8)) != nil {
                status = L.t("Gesichert als \(url.lastPathComponent). Häng die Datei an deine Meldung oder schick sie an \(Report.mail).",
                             "Saved as \(url.lastPathComponent). Attach the file to your report or send it to \(Report.mail).")
            } else {
                status = L.t("Konnte die Datei nicht sichern.", "Could not save the file.")
            }
        }
    }

    private func copy() {
        guard ready() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(full, forType: .string)
        status = L.t("Kopiert.", "Copied.")
    }
}

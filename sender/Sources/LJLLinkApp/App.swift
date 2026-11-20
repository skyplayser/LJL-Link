import AppKit
import SenderCore
import SwiftUI

@main
struct SenderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model.shared

    var body: some Scene {
        Window("LJL Link", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 600, idealWidth: 660, minHeight: 480)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 660, height: 720)
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            // The stick (template image, macOS tints it) while all is well; a warning symbol otherwise.
            if let icon = Brand.menuIcon, model.menuSymbol == "dot.radiowaves.left.and.right" {
                Image(nsImage: icon)
            } else {
                Image(systemName: model.menuSymbol)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window keeps sending; the menu bar icon stays. Quit ends it (and tells LJ Link).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Model.shared.stop() }
    }
}

extension Model {
    var menuSymbol: String {
        guard phase == .running else { return "dot.radiowaves.left.and.right" }
        switch link {
        // A warning goes before the chat bubble (QS 8).
        case .connected: return chatUnread > 0 ? "bubble.left.fill" : "dot.radiowaves.left.and.right"
        case .rejected: return "exclamationmark.triangle"
        default: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    /// Starts the app anew (macOS applies a new screen recording permission only after a restart).
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        stop()
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Logo (draft 4b "Fader-Stick", docs/logo-entwuerfe; files in Resources, copied into the app by build-app.sh)

enum Brand {
    static let logo: NSImage? = Bundle.main.url(forResource: "Logo", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    static let menuIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"), let i = NSImage(contentsOf: url) else { return nil }
        i.size = NSSize(width: 22, height: 22)
        i.isTemplate = true
        return i
    }()
}

// MARK: - Colours (LJ Link's look: dark panels, one accent)

enum Palette {
    static let bg = Color(red: 0.06, green: 0.07, blue: 0.09)
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.15)
    static let line = Color.white.opacity(0.08)
    static let dim = Color.white.opacity(0.55)
    static let accent = Color(red: 0.29, green: 0.75, blue: 0.93)
    static let ok = Color(red: 0.30, green: 0.80, blue: 0.45)
    static let warn = Color(red: 0.96, green: 0.70, blue: 0.25)
    static let bad = Color(red: 0.94, green: 0.33, blue: 0.27)
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
    }
}

func timeText(_ ms: Int64) -> String {
    let s = max(0, ms) / 1000
    return String(format: "%02d:%02d", s / 60, s % 60)
}

// MARK: - Window

struct MainView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(spacing: 0) {
            Header()
            Divider().overlay(Palette.line)
            ScrollView {
                VStack(spacing: 12) {
                    switch model.phase {
                    case .askNames: WelcomePanel(); NamesQuestion()
                    case .running: RunningView()
                    }
                }
                .padding(16)
            }
            Divider().overlay(Palette.line)
            Footer()
        }
        .background(Palette.bg)
        .sheet(isPresented: $model.showReport) { ReportSheet().environmentObject(model) }
        .sheet(isPresented: $model.showHelp) { HelpSheet() }
        // Back at the app: the booth's messages are read.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.chatUnread = 0 }
    }
}

struct Footer: View {
    @EnvironmentObject var model: Model
    var body: some View {
        HStack(spacing: 10) {
            Text("LJL Link \(Model.version) (Alpha)").font(.system(size: 11)).foregroundStyle(Palette.dim)
            Spacer()
            if model.phase == .running {
                Button(L.t("So funktioniert's", "How it works")) { model.showHelp = true }
            }
            Button(L.t("Fehler melden …", "Report a problem …")) { model.showReport = true }
            Button(L.t("Beenden", "Quit")) { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct Header: View {
    @EnvironmentObject var model: Model
    var body: some View {
        HStack(spacing: 10) {
            if let logo = Brand.logo {
                Image(nsImage: logo).resizable().interpolation(.high).frame(width: 36, height: 36)
            } else {
                Text("LJL").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(Color.black, in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("LJL Link").font(.system(size: 15, weight: .bold))
                    // Untested in a real club yet.
                    Text("ALPHA").font(.system(size: 9, weight: .heavy)).tracking(0.8).foregroundStyle(Palette.warn)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.warn.opacity(0.7)))
                        .help(L.t("Noch nicht im echten Club getestet.", "Not tested in a real club yet."))
                }
                Text((model.club?.club ?? model.boothName).map { L.t("Club: \($0)", "Club: \($0)") } ?? L.t("Ohne club.json", "Without club.json"))
                    .font(.system(size: 11)).foregroundStyle(Palette.dim)
            }
            Spacer()
            if model.phase == .running { LinkBadge() }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct LinkBadge: View {
    @EnvironmentObject var model: Model
    var color: Color {
        switch model.link {
        case .connected: return Palette.ok
        case .rejected: return Palette.bad
        default: return Palette.warn
        }
    }
    var label: String {
        switch model.link {
        case .connected: return L.t("Verbunden", "Connected")
        case .rejected: return L.t("Abgelehnt", "Refused")
        case .pending: return L.t("Warte auf Freigabe", "Waiting for approval")
        default: return L.t("Suche LJ Link", "Looking for LJ Link")
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// club.json is optional: with it LJL Link connects without asking the booth. Offered while not connected.
struct ClubFileHint: View {
    @EnvironmentObject var model: Model
    var body: some View {
        HStack(spacing: 8) {
            Text(L.t("Hat der Club dir eine club.json gegeben? Dann verbindet LJL Link ohne Freigabe.",
                     "Did the club give you a club.json? Then LJL Link connects without approval."))
                .font(.system(size: 12)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L.t("club.json wählen …", "Choose club.json …")) { model.chooseClub() }.controlSize(.small)
        }
        if let e = model.clubError { Text(e).font(.system(size: 12)).foregroundStyle(Palette.bad) }
    }
}

struct NamesQuestion: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Panel {
            Text(L.t("Tracknamen an die Lichttechnik senden?", "Send track names to the lighting booth?"))
                .font(.title3.bold())
            Text(L.t("Die Lichttechnik sieht dann Titel und Artist deiner Tracks. Ohne Tracknamen bekommt sie nur Tempo, Tonart, Waveform und Position; Titel, Artists und Dateinamen verlassen diesen Mac nicht. Du kannst das jederzeit ändern.",
                     "The lighting booth then sees title and artist of your tracks. Without track names it only gets tempo, key, waveform and position; titles, artists and file names never leave this Mac. You can change this at any time."))
                .foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { model.start(names: true) } label: {
                    Text(L.t("Ja, mit Tracknamen", "Yes, with track names")).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(Palette.accent)
                Button { model.start(names: false) } label: {
                    Text(L.t("Nein, ohne Tracknamen", "No, without track names")).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        Panel {
            Label(L.t("Die App steuert Serato nicht und greift nicht auf Controller oder MIDI zu. Sie liest Seratos Logdatei und die Zeitanzeige im Serato-Fenster. Installiert wird nichts.",
                      "The app does not control Serato and never touches controllers or MIDI. It reads Serato's log file and the time display in Serato's window. Nothing is installed."),
                  systemImage: "checkmark.shield")
                .font(.system(size: 12)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RunningView: View {
    @EnvironmentObject var model: Model
    @State private var showLog = false

    var body: some View {
        Panel {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("Verbindung", "Connection")).font(.headline)
                    Text(model.linkText).foregroundStyle(model.link == .rejected ? Palette.bad : Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            if model.club == nil && model.link != .connected { ClubFileHint() }
        }
        Panel {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.t("Tracknamen senden", "Send track names")).font(.headline)
                    Text(model.names
                         ? L.t("Titel und Artist gehen an LJ Link.", "Title and artist go to LJ Link.")
                         : L.t("Titel und Artist bleiben auf diesem Mac. Tempo, Tonart, Waveform und Position gehen an LJ Link.",
                               "Title and artist stay on this Mac. Tempo, key, waveform and position go to LJ Link."))
                        .font(.system(size: 12)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.names }, set: { model.setNames($0) }))
                    .labelsHidden().toggleStyle(.switch).tint(Palette.accent)
            }
        }
        ChatPanel()
        Panel {
            Text("Decks").font(.headline)
            if !model.seratoFound {
                Text(L.t("Serato wurde auf diesem Mac nicht gefunden (Ordner ~/Music/_Serato_). Serato öffnen – die App sucht weiter.",
                         "Serato was not found on this Mac (folder ~/Music/_Serato_). Open Serato – the app keeps looking."))
                    .foregroundStyle(Palette.warn).fixedSize(horizontal: false, vertical: true)
            } else if model.decks.isEmpty {
                Text(L.t("Noch kein Track in Serato geladen.", "No track loaded in Serato yet.")).foregroundStyle(Palette.dim)
            }
            ForEach(model.decks) { d in DeckRow(deck: d, names: model.names) }
        }
        ScreenPanel()
        Panel {
            DisclosureGroup(isExpanded: $showLog) {
                ScrollView {
                    Text(model.log.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.dim)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 160)
                Button(L.t("Protokoll kopieren", "Copy log")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log.joined(separator: "\n"), forType: .string)
                }
            } label: { Text(L.t("Protokoll", "Log")).font(.headline) }
        }
    }
}

struct DeckRow: View {
    let deck: Sender.DeckStatus
    let names: Bool
    var body: some View {
        HStack(spacing: 12) {
            Text("\(deck.deck)").font(.system(size: 18, weight: .heavy, design: .rounded))
                .frame(width: 34, height: 34).overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.7), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if !names {
                        Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Palette.dim)
                            .help(L.t("Nur auf diesem Mac sichtbar", "Only visible on this Mac"))
                    }
                    Text(deck.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                Text([deck.artist, deck.bpm.map { String(format: "%.1f BPM", $0) }, deck.key].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Palette.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                position
                Text(deck.waveform ? L.t("Waveform fertig", "Waveform ready") : L.t("Waveform wird berechnet …", "Building waveform …"))
                    .font(.system(size: 10)).foregroundStyle(deck.waveform ? Palette.dim : Palette.warn)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    @ViewBuilder var position: some View {
        if let p = deck.positionMs {
            HStack(spacing: 5) {
                Image(systemName: deck.playing ? "play.fill" : "pause.fill").font(.system(size: 10))
                Text("\(timeText(p)) / \(timeText(deck.lengthMs))").font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(deck.playing ? Palette.ok : .white)
        } else {
            Text(L.t("keine Position", "no position")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.dim)
                .help(L.t("Die Zeit dieses Decks ist gerade nicht lesbar, z. B. Deck 3 und 4 in der 2-Deck-Ansicht, keine Erlaubnis zur Bildschirmaufnahme oder die App misst noch ein.",
                          "This deck's time cannot be read right now, e.g. decks 3 and 4 in the 2-deck view, no screen recording permission, or the app is still calibrating."))
        }
    }
}

struct ScreenPanel: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Panel {
            Text(L.t("Position aus der Zeitanzeige", "Position from the time display")).font(.headline)
            switch model.screen {
            case .reading:
                Label(L.t("Seratos Zeitanzeige wird gelesen. Damit läuft die Waveform in LJ Link mit.",
                          "Serato's time display is being read, so the waveform runs along in LJ Link."), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.ok).fixedSize(horizontal: false, vertical: true)
                Text(L.t("Serato einfach offen lassen. Andere Fenster darüber stören nicht.",
                         "Just keep Serato open. Other windows on top do not matter."))
                    .font(.system(size: 12)).foregroundStyle(Palette.dim)
            case .denied:
                Text(L.t("Für die Position braucht die App die Erlaubnis zur Bildschirmaufnahme. Sie nutzt sie nur, um die Zeitanzeige im Serato-Fenster zu lesen (Einzelheiten in der Datenschutzerklärung); nichts wird gespeichert oder gesendet außer der Zeit.",
                         "For the position the app needs permission to record the screen. It uses it only to read the time display in Serato's window (details in the privacy policy); nothing is stored or sent except the time."))
                    .foregroundStyle(Palette.warn).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L.t("Erlauben …", "Allow …")) { model.allowScreen() }.buttonStyle(.borderedProminent).tint(Palette.accent)
                    Button(L.t("App neu starten", "Restart app")) { model.relaunch() }
                }
                Text(L.t("Ohne Erlaubnis sendet die App Tracks und Waveforms trotzdem, nur ohne mitlaufende Position.",
                         "Without permission the app still sends tracks and waveforms, only without the running position."))
                    .font(.system(size: 12)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            case .waiting:
                Label(L.t("Serato-Fenster nicht gefunden. Serato öffnen – die App sucht weiter.",
                          "Serato's window not found. Open Serato – the app keeps looking."), systemImage: "hourglass")
                    .foregroundStyle(Palette.warn)
            case .off:
                Text(L.t("Startet …", "Starting …")).foregroundStyle(Palette.dim)
            }
        }
    }
}

// MARK: - Menu bar

struct MenuView: View {
    @EnvironmentObject var model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.phase == .running {
            Text(model.linkText)
            if model.chatUnread > 0 {
                Button(L.t("\(model.chatUnread) neue Chat-Nachricht(en)", "\(model.chatUnread) new chat message(s)")) {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            Toggle(L.t("Tracknamen senden", "Send track names"), isOn: Binding(get: { model.names }, set: { model.setNames($0) }))
            Divider()
        }
        Button(L.t("Fenster zeigen", "Show window")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(L.t("Fehler melden …", "Report a problem …")) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            model.showReport = true
        }
        Divider()
        Button(L.t("LJL Link beenden", "Quit LJL Link")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

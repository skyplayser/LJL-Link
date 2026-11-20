import AppKit
import SenderCore
import SwiftUI

// The welcome: what LJL Link does and how, before the first question. Also later from the footer ("So funktioniert's").

struct WelcomePanel: View {
    var body: some View {
        Panel {
            HStack(alignment: .center, spacing: 14) {
                if let logo = Brand.logo {
                    Image(nsImage: logo).resizable().interpolation(.high).frame(width: 56, height: 56)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("Willkommen bei LJL Link", "Welcome to LJL Link")).font(.title2.bold())
                    Text(L.t("LJ LAN Link – damit die Lichttechnik in der Booth zu deiner Musik leuchten kann.",
                             "LJ LAN Link – so the lighting booth can light up to your music."))
                        .foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            // Two columns, so the question below stays in view.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18, alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 14) {
                Step(icon: "music.note.list", title: L.t("Du legst auf wie immer", "You play as usual"),
                     text: L.t("LJL Link liest mit, welcher Track auf welchem Deck liegt, und die Zeitanzeige im Serato-Fenster. Serato, Controller und MIDI fasst es nicht an.",
                               "LJL Link reads which track is on which deck, and the time display in Serato's window. It never touches Serato, controllers or MIDI."))
                Step(icon: "waveform", title: L.t("Die Booth sieht mit", "The booth follows along"),
                     text: L.t("Waveform, Tempo, Tonart und Position deiner Decks erscheinen in LJ Link bei der Lichttechnik. LJL Link findet LJ Link im Netzwerk selbst; beim ersten Mal klickt die Lichttechnik einmal auf „Erlauben“.",
                               "Waveform, tempo, key and position of your decks show up in LJ Link at the lighting booth. LJL Link finds LJ Link in the network by itself; the first time, the lighting tech clicks “Allow” once."))
                Step(icon: "lock.shield", title: L.t("Du entscheidest", "You decide"),
                     text: L.t("Tracknamen gehen nur raus, wenn du es erlaubst – jederzeit umschaltbar. LJL Link installiert nichts und läuft auch direkt vom USB-Stick.",
                               "Track names only go out if you allow it – switch it any time. LJL Link installs nothing and also runs straight from a USB stick."))
                Step(icon: "rectangle.dashed.badge.record", title: L.t("Zwei Fragen von macOS", "Two questions from macOS"),
                     text: L.t("„Lokales Netzwerk“: damit LJL Link LJ Link in der Booth findet. „Bildschirmaufnahme“: LJL Link nutzt sie nur, um die Zeitanzeige im Serato-Fenster zu lesen (Einzelheiten in der Datenschutzerklärung); nichts wird gespeichert oder gesendet außer der Zeit (ohne läuft alles, nur ohne mitlaufende Position).",
                               "“Local Network”: so LJL Link finds LJ Link in the booth. “Screen Recording”: LJL Link uses it only to read the time display in Serato's window (details in the privacy policy); nothing is stored or sent except the time (without it everything works, only without the running position)."))
                Step(icon: "bubble.left.and.bubble.right", title: L.t("Chat mit der Booth", "Chat with the booth"),
                     text: L.t("Alle Programme der Suite im selben Netzwerk – LJ Link in der Booth, VJ-Link – sind automatisch in einem Chatraum. Ihr könnt euch schreiben, ohne über die Tanzfläche zu rufen. Abschaltbar.",
                               "Every suite program in the same network – LJ Link in the booth, VJ-Link – is in one chat room by itself. Write to each other instead of shouting across the dance floor. Can be switched off."))
                Step(icon: "power", title: L.t("Am Ende deines Sets", "At the end of your set"),
                     text: L.t("„Beenden“ unten rechts (oder ⌘Q); läuft es vom Stick, danach den Stick abziehen. Fenster zu genügt nicht: LJL Link sendet dann aus der Menüleiste weiter.",
                               "“Quit” at the bottom right (or ⌘Q); running from a stick, unplug it afterwards. Closing the window is not enough: LJL Link keeps sending from the menu bar."))
            }
            .padding(.top, 4)
        }
    }
}

private struct Step: View {
    let icon: String
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(width: 22, alignment: .center).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                Text(text).font(.system(size: 12)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "So funktioniert's" later on, from the footer.
struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            ScrollView { WelcomePanel() }
            HStack {
                Spacer()
                Button(L.t("Schließen", "Close")) { dismiss() }.keyboardShortcut(.cancelAction).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .background(Palette.bg)
    }
}

// MARK: - Suite chat (Alpha)

struct ChatPanel: View {
    @EnvironmentObject var model: Model
    @State private var draft = ""
    @State private var nickDraft = ""
    @State private var whereDraft = ""
    @State private var renaming = false
    @FocusState private var focused: Bool

    var body: some View {
        Panel {
            HStack(spacing: 6) {
                Text("Chat").font(.headline)
                Text("ALPHA").font(.system(size: 9, weight: .heavy)).tracking(0.8).foregroundStyle(Palette.warn)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.warn.opacity(0.7)))
                Spacer()
                if model.chatOn, !model.chatNick.isEmpty, !renaming {
                    Button(L.t("Name ändern", "Change name")) { nickDraft = model.chatNick; whereDraft = model.chatWhere; renaming = true }
                        .buttonStyle(.link).font(.system(size: 11))
                }
                Toggle("", isOn: Binding(get: { model.chatOn }, set: { model.setChatOn($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Palette.accent)
                    .help(L.t("Chat ein- oder ausschalten", "Switch the chat on or off"))
            }
            if !model.chatOn {
                Text(L.t("Der Chat ist aus. Eingeschaltet bist du automatisch im Raum mit allen Programmen der Suite in diesem Netzwerk: LJ Link in der Booth, VJ-Link und andere DJs.",
                         "The chat is off. Switched on, you are in the room with every suite program in this network: LJ Link in the booth, VJ-Link and other DJs."))
                    .font(.system(size: 12)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            } else if model.chatNick.isEmpty || renaming {
                nickForm
            } else {
                room
            }
            if let note = model.chatNote {
                Text(note).font(.system(size: 11)).foregroundStyle(Palette.warn)
            }
        }
    }

    private var nickForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text(L.t("Name (Wie heißt du?)", "Name (What is your name?)")).font(.system(size: 12, weight: .semibold))
                    TextField(L.t("z. B. DJ David", "e.g. DJ David"), text: $nickDraft)
                        .textFieldStyle(.roundedBorder).focused($focused).onSubmit(join)
                }
                GridRow {
                    Text(L.t("Position (Wo stehst du?)", "Position (Where are you?)")).font(.system(size: 12, weight: .semibold))
                    TextField(L.t("z. B. DJ Booth, FOH, Bar", "e.g. DJ Booth, FOH, Bar"), text: $whereDraft)
                        .textFieldStyle(.roundedBorder).onSubmit(join)
                }
            }
            HStack {
                Spacer()
                Button(renaming ? L.t("Übernehmen", "Apply") : L.t("Chat betreten", "Join chat"), action: join)
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
                    .disabled(nickDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(L.t("Steht bei jeder Nachricht, z. B. „DJ David (DJ Booth) · LJL Link“. Name, Position und Nachrichten sehen alle im Netzwerk, unverschlüsselt – schreib nichts Vertrauliches. Nur für diesen Start, nichts wird auf dem Mac gespeichert.",
                     "Shown with every message, e.g. “DJ David (DJ Booth) · LJL Link”. Everyone in the network sees name, position and messages, unencrypted – write nothing confidential. Only for this start, nothing is stored on the Mac."))
                .font(.system(size: 11)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { focused = true }
    }

    private var room: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.chatMembers.isEmpty
                 ? L.t("Noch niemand sonst im Raum. Suite-Programme in diesem Netzwerk kommen von selbst dazu.",
                       "Nobody else in the room yet. Suite programs in this network join by themselves.")
                 : L.t("Im Raum: du, ", "In the room: you, ") + model.chatMembers.map { SuiteChat.who($0.nick, $0.where_, $0.app) }.joined(separator: ", "))
                .font(.system(size: 11)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.chatLines.isEmpty {
                            Text(L.t("Noch keine Nachrichten. Schreib der Booth z. B., wann der Drop kommt.",
                                     "No messages yet. Tell the booth when the drop comes, for example."))
                                .font(.system(size: 12)).foregroundStyle(Palette.dim)
                        }
                        ForEach(model.chatLines) { line in Bubble(line: line, urgent: line.urgent && !model.downgraded.contains(line.id)).id(line.id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 70, maxHeight: 170)
                .onChange(of: model.chatLines.count) { _, _ in
                    if let last = model.chatLines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            HStack(spacing: 8) {
                TextField(L.t("Nachricht an alle", "Message to everyone"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(send)
                Button(L.t("Senden", "Send"), action: send)
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(action: emergency) {
                    Text("EMERGENCY").font(.system(size: 11, weight: .heavy)).foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent).tint(Color(red: 1.0, green: 0.84, blue: 0.04))
                .help(L.t("Sofort ein Popup bei allen im Raum – mit deinem Text oder „EMERGENCY – bitte sofort kommen!“",
                          "A pop-up at everyone in the room at once – with your text or “EMERGENCY – please come at once!”"))
            }
        }
    }

    private func emergency() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.sendChat(t.isEmpty ? L.t("EMERGENCY – bitte sofort kommen!", "EMERGENCY – please come at once!") : t, urgent: true) { draft = "" }
    }

    private func join() {
        let n = nickDraft.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        model.setChatProfile(n, whereDraft.trimmingCharacters(in: .whitespaces))
        renaming = false
        focused = true
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if model.sendChat(t) { draft = "" }
        focused = true
    }
}

private struct Bubble: View {
    let line: SuiteChat.Line
    let urgent: Bool
    var body: some View {
        HStack {
            if line.mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(urgent ? "EMERGENCY · " : "")\(line.mine ? L.t("Du", "You") : SuiteChat.who(line.nick, line.where_, line.app)) · \(line.at.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(Palette.dim)
                Text(line.text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(line.mine ? Palette.accent.opacity(0.18) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 1.0, green: 0.84, blue: 0.04), lineWidth: urgent ? 2 : 0))
            if !line.mine { Spacer(minLength: 40) }
        }
    }
}

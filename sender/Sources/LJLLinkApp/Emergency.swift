import AppKit
import SenderCore
import SwiftUI

/// EMERGENCY messages of the suite chat: a pop-up at the bottom right of the screen with a yellow blinking border, above
/// every window (also above Serato in full screen), until the DJ clicks "OK". It never takes the keyboard from Serato
/// (a non-activating panel): the DJ's shortcuts keep working.
@MainActor
final class EmergencyPanel {
    static let shared = EmergencyPanel()
    private var panel: NSPanel?
    private var waiting: [SuiteChat.Line] = []

    /// At most 20 open (spec): more stay normal messages in the chat, without a pop-up; nothing open is thrown away.
    @discardableResult
    func show(_ line: SuiteChat.Line) -> Bool {
        guard waiting.count < 20 else { return false }
        waiting.append(line)
        present()
        return true
    }

    /// The chat switched off: no pop-up stays.
    func closeAll() {
        waiting.removeAll()
        present()
    }

    /// "Close all" in the pop-up: only the ones shown so far ("n more"), not one that came in the same moment.
    func close(first n: Int) {
        waiting.removeFirst(min(n, waiting.count))
        present()
    }

    private func present() {
        guard let line = waiting.first else {
            panel?.orderOut(nil)
            return
        }
        let view = EmergencyView(line: line, more: waiting.count - 1, ok: { [weak self] in
            guard let self, !self.waiting.isEmpty else { return }
            self.waiting.removeFirst()
            self.present()
        }, all: { [weak self, shown = waiting.count] in self?.close(first: shown) })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = panel ?? makePanel()
        panel = p
        p.contentView = host
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        p.setFrame(NSRect(x: screen.maxX - size.width - 20, y: screen.minY + 20, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        return p
    }
}

private struct EmergencyView: View {
    let line: SuiteChat.Line
    let more: Int
    let ok: () -> Void
    let all: () -> Void
    @State private var bright = true
    private let yellow = Color(red: 1.0, green: 0.84, blue: 0.04)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(yellow)
                Text("EMERGENCY").font(.system(size: 15, weight: .heavy)).tracking(1.2).foregroundStyle(yellow)
                Spacer()
                Text(line.at.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(Palette.dim)
            }
            Text(SuiteChat.who(line.nick, line.where_, line.app)).font(.system(size: 12)).foregroundStyle(Palette.dim)
            Text(line.text).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if more > 0 {
                    Text(L.t("\(more) weitere", "\(more) more")).font(.system(size: 11)).foregroundStyle(Palette.dim)
                    Button(L.t("Alle schließen", "Close all"), action: all).buttonStyle(.link).font(.system(size: 11))
                }
                Spacer()
                // Yellow also while LJL Link is not the active app (a system button turns grey then).
                Button(action: ok) {
                    Text("OK").font(.system(size: 13, weight: .heavy)).foregroundStyle(.black)
                        .padding(.horizontal, 18).padding(.vertical, 6)
                        .background(yellow, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(Palette.bg, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(yellow.opacity(bright ? 1 : 0.12), lineWidth: 5))
        .padding(6)
        .preferredColorScheme(.dark)
        .onAppear {
            // "Reduce motion": a steady yellow border instead of blinking.
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { bright.toggle() }
        }
    }
}

import AppKit
import SwiftUI

/// A script that scrolls in a small window right under the camera, so you look at the lens while
/// reading. The window is hidden from screen sharing and recordings.
@MainActor
final class Teleprompter: ObservableObject {
    @AppStorage("prompter.script") var script = ""
    @AppStorage("prompter.speed") var speed = 30.0
    @AppStorage("prompter.size") var size = 22.0
    @Published private(set) var isShowing = false
    @Published var paused = false
    /// Points scrolled so far.
    @Published var offset: CGFloat = 0

    private var window: NSPanel?
    private var timer: Timer?

    func show() {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Services.shared.collapsePanel()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = CGSize(width: 560, height: 150)
        // Just under the menu bar, centred on the camera.
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 4, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PrompterOverlay(prompter: self))
        panel.orderFrontRegardless()
        window = panel
        offset = 0
        paused = false
        isShowing = true
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.paused else { return }
                self.offset += CGFloat(self.speed) / 60
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func close() {
        timer?.invalidate()
        timer = nil
        window?.close()
        window = nil
        isShowing = false
    }
}

private struct PrompterOverlay: View {
    @ObservedObject var prompter: Teleprompter
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(prompter.script)
                .font(.system(size: prompter.size, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 60)
                .offset(y: -prompter.offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
                // Fade in and out at the edges, so lines appear and leave softly.
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25),
                                             .init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            if hovering {
                HStack(spacing: 4) {
                    IconButton(icon: "minus", help: "Slower", size: 10) { prompter.speed = max(5, prompter.speed - 5) }
                    IconButton(icon: prompter.paused ? "play.fill" : "pause.fill", help: "Pause", size: 10) { prompter.paused.toggle() }
                    IconButton(icon: "plus", help: "Faster", size: 10) { prompter.speed = min(200, prompter.speed + 5) }
                    IconButton(icon: "backward.end.fill", help: "From the start", size: 10) { prompter.offset = 0 }
                    IconButton(icon: "xmark", help: "Close", size: 10, action: prompter.close)
                }
                .padding(6)
                .background(Capsule().fill(.black.opacity(0.7)))
                .padding(8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.82)))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { hovering = $0 }
        .environment(\.colorScheme, .dark)
    }
}

/// Write or paste the script, set speed and size, start.
struct TeleprompterView: View {
    @ObservedObject var prompter: Teleprompter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompter.script)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if prompter.script.isEmpty {
                    Text("Paste or write what you want to say. It scrolls right under the camera, and people on the call don't see it.")
                        .font(Theme.caption(12, weight: .regular)).foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            HStack(spacing: 14) {
                Label("Speed", systemImage: "speedometer").font(Theme.caption(11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                Slider(value: $prompter.speed, in: 5...120).frame(width: 140)
                Label("Size", systemImage: "textformat.size").font(Theme.caption(11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                Slider(value: $prompter.size, in: 14...40).frame(width: 110)
                Spacer()
                if prompter.isShowing {
                    PillButton(title: "Stop", icon: "stop.fill", tint: Theme.red, action: prompter.close)
                } else {
                    PillButton(title: "Start", icon: "play.fill", action: prompter.show)
                        .disabled(prompter.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

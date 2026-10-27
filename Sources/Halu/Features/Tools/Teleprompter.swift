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
            PrompterText(script: prompter.script, size: prompter.size, offset: prompter.offset)
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

/// The script as it scrolls: full height (never cut to "…"), moved up by `offset`, fading at the edges.
struct PrompterText: View {
    let script: String
    let size: Double
    let offset: CGFloat

    var body: some View {
        Text(script)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
            .padding(.top, 60)
            .offset(y: -offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25),
                                         .init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
    }
}

/// The overlay in miniature, looping at the chosen size and speed, so the sliders show what they do.
private struct PrompterPreview: View {
    @ObservedObject var prompter: Teleprompter
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            // Loop once the text has scrolled past (its height estimated for the 560 pt window).
            let height = (prompter.script as NSString).boundingRect(
                with: CGSize(width: 512, height: CGFloat.greatestFiniteMagnitude), options: .usesLineFragmentOrigin,
                attributes: [.font: NSFont.systemFont(ofSize: prompter.size, weight: .semibold)]).height + 60
            let travelled = CGFloat(context.date.timeIntervalSince(start) * prompter.speed)
            PrompterText(script: prompter.script.isEmpty ? "Your text scrolls here, at this size and speed." : prompter.script,
                         size: prompter.size, offset: travelled.truncatingRemainder(dividingBy: max(height, 120)))
        }
        .frame(width: 560, height: 150)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topLeading) {
            Text("PREVIEW").font(Theme.caption(9, weight: .bold)).tracking(0.6).foregroundStyle(.white.opacity(0.4)).padding(10)
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: prompter.speed) { start = Date() }
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
            PrompterPreview(prompter: prompter).frame(maxWidth: .infinity)
            HStack(spacing: 14) {
                Label("Speed", systemImage: "speedometer").font(Theme.caption(11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                Slider(value: $prompter.speed, in: 5...120).frame(width: 140)
                Text("\(Int(prompter.speed)) pt/s").font(Theme.caption(10.5, weight: .medium)).monospacedDigit().foregroundStyle(Theme.tertiary)
                Label("Size", systemImage: "textformat.size").font(Theme.caption(11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                Slider(value: $prompter.size, in: 14...40).frame(width: 110)
                Text("\(Int(prompter.size)) pt").font(Theme.caption(10.5, weight: .medium)).monospacedDigit().foregroundStyle(Theme.tertiary)
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

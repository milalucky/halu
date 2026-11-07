import AppKit
import SwiftUI

/// A script that scrolls in a small window right under the camera, so you look at the lens while
/// reading. The window is hidden from screen sharing and recordings.
@MainActor
final class Teleprompter: ObservableObject {
    @AppStorage("prompter.script") var script = ""
    @AppStorage("prompter.speed") var speed = 30.0
    @AppStorage("prompter.size") var size = 22.0
    /// White background with dark text, for reading in a bright room.
    @AppStorage("prompter.light") var light = false
    /// How solid the panel's tint is over the blur (0.3 airy … 1 solid).
    @AppStorage("prompter.opacity") var opacity = 0.75
    @AppStorage("prompter.width") private var width = 600.0
    @AppStorage("prompter.height") private var height = 170.0
    @Published private(set) var isShowing = false
    @Published var paused = false
    /// Points scrolled so far.
    @Published var offset: CGFloat = 0

    private var window: NSPanel?
    private var timer: Timer?
    /// Room around the rounded panel for its shadow.
    static let margin: CGFloat = 18

    func show() {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Services.shared.collapsePanel()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = CGSize(width: width + Self.margin * 2, height: height + Self.margin * 2)
        // Just under the menu bar, centred on the camera.
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height + Self.margin - 4,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The rounded panel draws its own shadow; the window's would be square.
        panel.hasShadow = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: PrompterOverlay(prompter: self))
        // The text is taller than the window; don't let it resize the window to fit.
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
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

    /// Where a drag started: the window's frame and the pointer, in screen coordinates. Following the
    /// pointer on screen keeps the window steady even though the view moves with it.
    private var dragStart: (frame: CGRect, mouse: CGPoint)?

    enum Drag { case move, resize }

    func drag(_ kind: Drag) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let start = dragStart ?? (window.frame, mouse)
        dragStart = start
        let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
        switch kind {
        case .move:
            window.setFrameOrigin(CGPoint(x: start.frame.origin.x + dx, y: start.frame.origin.y + dy))
        case .resize:
            // Bottom-right corner: wider to the right, taller downwards; the top edge stays put.
            let newWidth = max(320, start.frame.width + dx), newHeight = max(100, start.frame.height - dy)
            window.setFrame(CGRect(x: start.frame.minX, y: start.frame.maxY - newHeight, width: newWidth, height: newHeight), display: true)
            width = newWidth - Self.margin * 2
            height = newHeight - Self.margin * 2
        }
    }

    func endDrag() { dragStart = nil }

    func close() {
        timer?.invalidate()
        timer = nil
        window?.close()
        window = nil
        isShowing = false
    }
}

/// The floating panel: blurred and tinted, rounded, with controls on hover, draggable, and a corner grip to resize.
private struct PrompterOverlay: View {
    @ObservedObject var prompter: Teleprompter
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        ZStack(alignment: .topTrailing) {
            PrompterText(script: prompter.script, size: prompter.size, offset: prompter.offset, light: prompter.light)
            if hovering {
                HStack(spacing: 4) {
                    IconButton(icon: "minus", help: "Slower", size: 10) { prompter.speed = max(5, prompter.speed - 5) }
                    IconButton(icon: prompter.paused ? "play.fill" : "pause.fill", help: "Pause", size: 10) { prompter.paused.toggle() }
                    IconButton(icon: "plus", help: "Faster", size: 10) { prompter.speed = min(200, prompter.speed + 5) }
                    IconButton(icon: "backward.end.fill", help: "From the start", size: 10) { prompter.offset = 0 }
                    IconButton(icon: "xmark", help: "Close", size: 10, action: prompter.close)
                }
                .padding(6)
                .background(Capsule().fill(.black.opacity(0.55)))
                .environment(\.colorScheme, .dark)
                .padding(10)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Always there, brighter on hover, so it's clear the panel can be resized.
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle((prompter.light ? Color.black : Color.white).opacity(hovering ? 0.7 : 0.3))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { _ in prompter.drag(.resize) }.onEnded { _ in prompter.endDrag() })
                    .help("Drag to resize")
                    .padding(6)
        }
        .background {
            ZStack {
                VisualBlur()
                (prompter.light ? Color.white : Color.black).opacity(prompter.opacity)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder((prompter.light ? Color.black : Color.white).opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .padding(Teleprompter.margin)
        .gesture(DragGesture().onChanged { _ in prompter.drag(.move) }.onEnded { _ in prompter.endDrag() })
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
    }
}

/// The system's behind-window blur, like the Control Centre panels.
private struct VisualBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A labelled slider with its value, laid out on one line.
private struct SettingSlider: View {
    let icon: String
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let readout: String

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: icon).font(Theme.caption(11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                .lineLimit(1).fixedSize()
            Slider(value: $value, in: range).frame(minWidth: 90)
            Text(readout).font(Theme.caption(10.5, weight: .medium)).monospacedDigit().foregroundStyle(Theme.tertiary)
                .frame(width: 52, alignment: .leading)
        }
    }
}

/// The script as it scrolls: full height (never cut to "…"), moved up by `offset`, fading at the edges.
struct PrompterText: View {
    let script: String
    let size: Double
    let offset: CGFloat
    var light = false

    var body: some View {
        Text(script)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(light ? Color.black : Color.white)
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
                         size: prompter.size, offset: travelled.truncatingRemainder(dividingBy: max(height, 120)), light: prompter.light)
        }
        .frame(width: 560, height: 150)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill((prompter.light ? Color.white : Color.black).opacity(prompter.opacity)))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder((prompter.light ? Color.black : Color.white).opacity(0.12)))
        .overlay(alignment: .topLeading) {
            Text("PREVIEW").font(Theme.caption(9, weight: .bold)).tracking(0.6).foregroundStyle((prompter.light ? Color.black : Color.white).opacity(0.4)).padding(10)
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
            HStack(spacing: 18) {
                SettingSlider(icon: "speedometer", title: "Speed", value: $prompter.speed, range: 5...120, readout: "\(Int(prompter.speed)) pt/s")
                SettingSlider(icon: "textformat.size", title: "Size", value: $prompter.size, range: 14...40, readout: "\(Int(prompter.size)) pt")
            }
            HStack(spacing: 18) {
                SettingSlider(icon: "circle.lefthalf.filled", title: "Opacity", value: $prompter.opacity, range: 0.3...1,
                              readout: "\(Int(prompter.opacity * 100))%")
                Toggle(isOn: $prompter.light) {
                    Text("Light").font(Theme.caption(11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                .toggleStyle(.switch).controlSize(.mini).fixedSize()
                .help("White background with dark text")
                Spacer()
                Text("Drag the panel to move it, its corner to resize")
                    .font(Theme.caption(10.5, weight: .regular)).foregroundStyle(Theme.tertiary).lineLimit(1)
                Group {
                    if prompter.isShowing {
                        PillButton(title: "Stop", icon: "stop.fill", tint: Theme.red, action: prompter.close)
                    } else {
                        PillButton(title: "Start", icon: "play.fill", action: prompter.show)
                            .disabled(prompter.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .fixedSize()
            }
        }
    }
}

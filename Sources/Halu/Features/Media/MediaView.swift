import SwiftUI

struct MediaView: View {
    @ObservedObject var store: MediaStore

    var body: some View {
        Group {
            if let source = store.source {
                if let playback = store.browser {
                    BrowserPlayer(playback: playback, source: source, store: store)
                } else {
                    AppPlayer(source: source, store: store)
                }
            } else {
                EmptyState(icon: "play.circle", title: "Nothing is playing",
                           subtitle: "Start a video or music anywhere, in a browser, Yandex Music or any other app, and it shows up here.")
            }
        }
        .onAppear {
            store.isVisible = true
            store.refresh()
        }
        .onDisappear { store.isVisible = false }
    }
}

/// A video or song in a browser tab, driven through the page's own player.
private struct BrowserPlayer: View {
    let playback: BrowserPlayback
    let source: MediaSource
    @ObservedObject var store: MediaStore

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card)
                if let artwork = store.browserArtwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else if let icon = store.icon {
                    Image(nsImage: icon).resizable().frame(width: 64, height: 64)
                }
            }
            .frame(width: 170, height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            .onTapGesture(perform: store.openApp)
            .help("Open \(source.appName)")

            VStack(alignment: .leading, spacing: 6) {
                Text(playback.artist.uppercased())
                    .font(Theme.caption(10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                Text(playback.title)
                    .font(Theme.title(16))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(3)
                Spacer(minLength: 6)
                if playback.duration > 0 {
                    Scrubber(duration: playback.duration, position: playback.position(at:)) { store.browserCommand(.seek($0)) }
                }
                HStack(spacing: 18) {
                    Spacer()
                    TransportButton(icon: "gobackward.10", size: 16) { store.browserCommand(.skip(-10)) }
                    TransportButton(icon: playback.isPlaying ? "pause.fill" : "play.fill", size: 22, prominent: true) {
                        store.browserCommand(.toggle)
                    }
                    TransportButton(icon: "goforward.10", size: 16) { store.browserCommand(.skip(10)) }
                    TransportButton(icon: "forward.end.fill", size: 14) { store.browserCommand(.next) }
                    Spacer()
                }
            }
            .frame(maxHeight: 170)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Any other app: what Core Audio and the window title tell, plus media keys.
private struct AppPlayer: View {
    let source: MediaSource
    @ObservedObject var store: MediaStore

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            HStack(spacing: 18) {
                ZStack(alignment: .bottomTrailing) {
                    if let icon = store.icon {
                        Image(nsImage: icon).resizable().frame(width: 96, height: 96)
                    }
                    if source.isPlaying {
                        Equalizer()
                            .padding(6)
                            .background(Circle().fill(.black.opacity(0.75)))
                            .offset(x: 4, y: 4)
                    }
                }
                .onTapGesture(perform: store.openApp)
                .help("Open \(source.appName)")

                VStack(alignment: .leading, spacing: 6) {
                    Text((source.isPlaying ? "Playing in " : "Paused in ") + source.appName)
                        .font(Theme.caption(11, weight: .semibold))
                        .foregroundStyle(source.isPlaying ? Theme.accent : Theme.tertiary)
                    Text(source.title ?? source.appName)
                        .font(Theme.title(17))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(3)
                    if store.isBrowserSource && store.browserScriptingOff {
                        Text("To control the video and see its cover, turn on View → Developer → Allow JavaScript from Apple Events in \(source.appName) (in Safari: Develop menu).")
                            .font(Theme.caption(11.5, weight: .regular))
                            .foregroundStyle(Theme.orange)
                    } else if source.title == nil && !store.canControl {
                        Text("Allow Accessibility to see what's playing and control it.")
                            .font(Theme.caption(11.5, weight: .regular))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Media keys only for apps: in a browser they can wake Apple Music up instead.
            if !store.isBrowserSource {
                if store.canControl {
                    HStack(spacing: 28) {
                        TransportButton(icon: "backward.fill", size: 17) { store.send(.previous) }
                        TransportButton(icon: source.isPlaying ? "pause.fill" : "play.fill", size: 22, prominent: true) {
                            store.send(.playPause)
                        }
                        TransportButton(icon: "forward.fill", size: 17) { store.send(.next) }
                    }
                } else {
                    PillButton(title: "Allow Accessibility", icon: "hand.raised", action: store.requestAccess)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }
}

/// Thin progress line you can drag or click to jump.
private struct Scrubber: View {
    let duration: TimeInterval
    let position: (Date) -> TimeInterval
    let onSeek: (TimeInterval) -> Void
    @State private var dragging: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let current = dragging.map { $0 * duration } ?? position(context.date)
            let fraction = duration > 0 ? min(1, current / duration) : 0
            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(Theme.primary).frame(width: max(4, geo.size.width * fraction))
                    }
                    .frame(height: hovering || dragging != nil ? 6 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in dragging = min(max(value.location.x / geo.size.width, 0), 1) }
                            .onEnded { _ in
                                if let dragging { onSeek(dragging * duration) }
                                dragging = nil
                            }
                    )
                }
                .frame(height: 12)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)

                HStack {
                    Text(Self.clock(current))
                    Spacer()
                    Text("-" + Self.clock(max(0, duration - current)))
                }
                .font(Theme.caption(10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.tertiary)
            }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Three bars bouncing while sound plays.
private struct Equalizer: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 3, height: 4 + 9 * abs(sin(t * (3.2 + Double(index)) + Double(index))))
                }
            }
            .frame(width: 14, height: 14, alignment: .bottom)
        }
    }
}

private struct TransportButton: View {
    let icon: String
    var size: CGFloat
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : (hovering ? Theme.primary : Theme.secondary))
                .frame(width: prominent ? 52 : 36, height: prominent ? 52 : 36)
                .background(Circle().fill(prominent ? Theme.primary.opacity(hovering ? 1 : 0.92) : (hovering ? Theme.card : .clear)))
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

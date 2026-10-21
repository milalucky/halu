import SwiftUI

struct MediaView: View {
    @ObservedObject var store: MediaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let playing = store.nowPlaying {
                PlayerCard(playing: playing, store: store)
            } else {
                EmptyState(icon: "music.note", title: "Nothing playing in Music or Spotify",
                           subtitle: "Their track shows up here. For a video in the browser or any other app, use the controls below.")
            }
            AnyAppControls(store: store)
        }
        .onAppear(perform: store.refresh)
    }
}

private struct PlayerCard: View {
    let playing: NowPlaying
    @ObservedObject var store: MediaStore

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card)
                if let artwork = store.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.tertiary)
                }
            }
            .frame(width: 150, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            .onTapGesture(perform: store.openPlayer)
            .help("Open \(playing.player.rawValue)")

            VStack(alignment: .leading, spacing: 6) {
                Text(playing.player.rawValue.uppercased())
                    .font(Theme.caption(10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.accent)
                Text(playing.title)
                    .font(Theme.title(17))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(2)
                Text([playing.artist, playing.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.body(12.5))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Scrubber(playing: playing, onSeek: store.seek)
                HStack(spacing: 26) {
                    Spacer()
                    TransportButton(icon: "backward.fill", size: 16, action: store.previous)
                    TransportButton(icon: playing.isPlaying ? "pause.fill" : "play.fill", size: 22, prominent: true,
                                    action: store.playPause)
                    TransportButton(icon: "forward.fill", size: 16, action: store.next)
                    Spacer()
                }
                .padding(.top, 2)
            }
            .frame(maxHeight: 150)
        }
    }
}

/// Thin progress line you can drag or click to jump.
private struct Scrubber: View {
    let playing: NowPlaying
    let onSeek: (TimeInterval) -> Void
    @State private var dragging: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let position = dragging.map { $0 * playing.duration } ?? playing.position(at: context.date)
            let fraction = playing.duration > 0 ? min(1, position / playing.duration) : 0
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
                                if let dragging { onSeek(dragging * playing.duration) }
                                dragging = nil
                            }
                    )
                }
                .frame(height: 12)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)

                HStack {
                    Text(Self.clock(position))
                    Spacer()
                    Text("-" + Self.clock(max(0, playing.duration - position)))
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
                .frame(width: prominent ? 46 : 32, height: prominent ? 46 : 32)
                .background(Circle().fill(prominent ? Theme.primary.opacity(hovering ? 1 : 0.92) : (hovering ? Theme.card : .clear)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contentTransition(.symbolEffect(.replace))
    }
}

/// Media keys: go to whatever macOS considers "now playing", e.g. a YouTube tab.
private struct AnyAppControls: View {
    @ObservedObject var store: MediaStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Any app").font(Theme.body(12.5, weight: .semibold)).foregroundStyle(Theme.primary)
                Text(store.canSendMediaKeys ? "Browser videos, podcasts and other players"
                                            : "Needs Accessibility access to press media keys")
                    .font(Theme.caption(11, weight: .regular))
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer()
            if store.canSendMediaKeys {
                IconButton(icon: "backward.fill", help: "Previous", size: 11) { store.send(.previous) }
                IconButton(icon: "playpause.fill", help: "Play / Pause", size: 12) { store.send(.playPause) }
                IconButton(icon: "forward.fill", help: "Next", size: 11) { store.send(.next) }
            } else {
                PillButton(title: "Allow", prominent: false, action: store.requestMediaKeyAccess)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }
}

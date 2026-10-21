import SwiftUI

struct MediaView: View {
    @ObservedObject var store: MediaStore

    var body: some View {
        if let source = store.source {
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
                        if source.title == nil && !store.canControl {
                            Text("Allow Accessibility to see what's playing and control it.")
                                .font(Theme.caption(11.5, weight: .regular))
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

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
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        } else {
            EmptyState(icon: "play.circle", title: "Nothing is playing",
                       subtitle: "Start a video or music anywhere, in a browser, Yandex Music or any other app, and it shows up here.")
        }
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

import SwiftUI

struct SectionHeader: View {
    let title: String
    var detail: String?
    var trailing: AnyView?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Theme.title()).foregroundStyle(Theme.primary)
            if let detail {
                Text(detail).font(Theme.caption()).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.8))
                .padding(.bottom, 2)
            Text(title).font(Theme.body(13, weight: .semibold)).foregroundStyle(Theme.primary)
            Text(subtitle)
                .font(Theme.caption(12, weight: .regular))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let action {
                PillButton(title: action.title, action: action.run).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PillButton: View {
    let title: String
    var icon: String?
    var tint: Color = Theme.accent
    var prominent = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                Text(title).font(Theme.caption(12, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : tint)
            .modifier(PillBackground(prominent: prominent, tint: tint, hovering: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? 1.04 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
    }
}

/// Solid for the main action, Liquid Glass for the rest.
private struct PillBackground: ViewModifier {
    let prominent: Bool
    let tint: Color
    let hovering: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.background(Capsule().fill(tint.opacity(hovering ? 1 : 0.9)))
        } else {
            content.glass(Capsule(), tint: tint, interactive: true)
        }
    }
}

struct IconButton: View {
    let icon: String
    var help: String = ""
    var size: CGFloat = 11
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(hovering ? Theme.primary : Theme.tertiary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(hovering ? Theme.cardHover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct InputField: View {
    let placeholder: String
    var icon: String = "plus"
    @Binding var text: String
    var speech: SpeechInput?
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool
    @State private var fieldID = UUID()
    @State private var dictationPrefix = ""

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(focused ? Theme.accent : Theme.tertiary)
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(Theme.body())
                .foregroundStyle(Theme.primary)
                .focused($focused)
                .onSubmit(onSubmit)
            if let speech {
                VoiceButton(speech: speech, fieldID: fieldID) { dictated in
                    text = dictationPrefix.isEmpty ? dictated : "\(dictationPrefix) \(dictated)"
                    focused = true
                } onStart: {
                    dictationPrefix = text.trimmingCharacters(in: .whitespaces)
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, speech == nil ? 12 : 5)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.45) : Theme.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

/// Mic with a language chip. Recording turns it red and streams the words into the field.
struct VoiceButton: View {
    @ObservedObject var speech: SpeechInput
    let fieldID: UUID
    let onText: (String) -> Void
    let onStart: () -> Void
    @State private var hovering = false

    var body: some View {
        let recording = speech.isRecording(for: fieldID)
        HStack(spacing: 2) {
            Button(action: speech.toggleLanguage) {
                Text(speech.languageLabel)
                    .font(Theme.caption(9.5, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Dictation language")

            Button {
                if !recording { onStart() }
                speech.toggle(for: fieldID, onText: onText)
            } label: {
                Image(systemName: recording ? "waveform" : "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: recording)
                    .foregroundStyle(recording ? Theme.red : (hovering ? Theme.primary : Theme.secondary))
                    .frame(width: 26, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(recording ? Theme.red.opacity(0.16) : (hovering ? Theme.cardHover : .clear))
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(speech.problem ?? (recording ? "Stop dictation" : "Dictate"))

            if recording {
                LevelBars(level: speech.level).transition(.opacity)
            }
        }
    }
}

/// Five bars that follow the microphone level.
struct LevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let threshold = Float(index) / 5
                Capsule()
                    .fill(level > threshold ? Theme.red : Theme.tertiary.opacity(0.4))
                    .frame(width: 2.5, height: 5 + CGFloat(index) * 2.5)
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.08), value: level)
        .help(level < 0.05 ? "No sound from the microphone" : "Listening")
    }
}

/// Thin capsule bar; `value == nil` draws an indeterminate sweep.
struct ProgressLine: View {
    var value: Double?
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                if let value {
                    Capsule().fill(tint).frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
                } else {
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        let width = geo.size.width * 0.3
                        Capsule()
                            .fill(LinearGradient(colors: [tint.opacity(0), tint, tint.opacity(0)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: width)
                            .offset(x: -width + (geo.size.width + width) * phase)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 3)
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

struct HoverRow<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 8)
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.card : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

import SwiftUI

struct TranslateView: View {
    @ObservedObject var store: TranslateStore
    @ObservedObject var speech: SpeechInput
    @State private var fieldID = UUID()
    @State private var copied = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(store.source.name).foregroundStyle(Theme.primary)
                Button(action: store.swap) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 26, height: 22)
                        .background(Capsule().fill(Theme.accent.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help("Swap languages")
                Text(store.target.name).foregroundStyle(Theme.primary)
                Spacer()
                if store.manualSource == nil {
                    Text("auto").font(Theme.caption(11, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
            }
            .font(Theme.title(14))

            // Source
            VStack(alignment: .leading, spacing: 6) {
                TextField("", text: $store.input,
                          prompt: Text("Type or dictate in English or Russian").foregroundStyle(Theme.tertiary),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(3...5)
                    .focused($focused)
                HStack(spacing: 6) {
                    VoiceButton(speech: speech, fieldID: fieldID) { dictated in
                        store.input = dictated
                    } onStart: {
                        speech.language = store.manualSource?.speechLocale ?? speech.language
                    }
                    if let problem = speech.problem {
                        Text(problem).font(Theme.caption(11, weight: .regular)).foregroundStyle(Theme.orange).lineLimit(1)
                    }
                    Spacer()
                    if !store.input.isEmpty {
                        IconButton(icon: "xmark", help: "Clear", size: 9, action: store.clear)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(focused ? Theme.accent.opacity(0.45) : Theme.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            // Translation
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(store.output.isEmpty ? "Translation" : store.output)
                        .font(Theme.body(14))
                        .foregroundStyle(store.output.isEmpty ? Theme.tertiary : Theme.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                HStack {
                    if store.isLoading {
                        ProgressView().controlSize(.mini)
                    } else if let problem = store.problem {
                        Text(problem).font(Theme.caption(11, weight: .regular)).foregroundStyle(Theme.orange)
                    }
                    Spacer()
                    PillButton(title: copied ? "Copied" : "Copy", icon: copied ? "checkmark" : "doc.on.doc",
                               tint: copied ? Theme.green : Theme.accent) {
                        store.copyOutput()
                        withAnimation(.easeOut(duration: 0.15)) { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            withAnimation(.easeOut(duration: 0.2)) { copied = false }
                        }
                    }
                    .disabled(store.output.isEmpty)
                    .opacity(store.output.isEmpty ? 0.4 : 1)
                }
            }
            .padding(12)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.06)))
        }
    }
}

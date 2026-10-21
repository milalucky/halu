import SwiftUI

struct ToolsView: View {
    @ObservedObject var store: ToolsStore
    let compare: CompareStore
    @ObservedObject var screen: ScreenTools
    let market: MarketStore
    @Namespace private var modes

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // Icons for every mode, the name only on the chosen one.
                HStack(spacing: 2) {
                    ForEach(ToolsStore.Mode.allCases) { mode in
                        ModeButton(mode: mode, selected: store.mode == mode, namespace: modes) {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { store.mode = mode }
                        }
                    }
                }
                .padding(2)
                .background(Capsule().fill(Theme.card))
                Spacer()
                // Screen utilities: one click each.
                ToolButton(icon: "eyedropper", title: screen.hex ?? "Color", swatch: screen.color.map(Color.init(nsColor:)),
                           help: "Pick a colour anywhere on screen; its hex is copied", action: screen.pickColor)
                ToolButton(icon: "web.camera", title: "Mirror", help: "See yourself before a call") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.showingMirror = true }
                }
                ToolButton(icon: "ruler", title: "Ruler", help: screen.lastMeasure.map { "Last: \($0)" } ?? "Measure anything on screen in pixels",
                           action: screen.showRuler)
            }
            if store.showingMirror {
                MirrorView { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.showingMirror = false } }
            } else {
            switch store.mode {
            case .generate: GenerateView(store: store)
            case .convert: ConvertView(store: store)
            case .compare: CompareView(store: compare)
            case .calculator: CalculatorView(market: market)
            case .emoji: EmojiView(market: market)
            case .stocks: StocksView(market: market)
            }
            }
        }
    }
}

private struct ModeButton: View {
    let mode: ToolsStore.Mode
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: mode.icon).font(.system(size: 11, weight: .semibold))
                if selected { Text(mode.rawValue).font(Theme.caption(11.5, weight: .semibold)).fixedSize() }
            }
            .foregroundStyle(selected ? Theme.onPrimary : (hovering ? Theme.primary : Theme.secondary))
            .padding(.horizontal, selected ? 10 : 8)
            .frame(height: 24)
            .background {
                if selected { Capsule().fill(Theme.accent).matchedGeometryEffect(id: "mode", in: namespace) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(mode.rawValue)
    }
}

private struct ToolButton: View {
    let icon: String
    let title: String
    var swatch: Color?
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 3).fill(swatch).frame(width: 11, height: 11)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.3)))
                } else {
                    Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                }
                Text(title).font(Theme.caption(11.5, weight: .semibold)).monospaced(swatch != nil)
            }
            .foregroundStyle(hovering ? Theme.primary : Theme.secondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(hovering ? Theme.cardHover : Theme.card))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// One click copies a value and makes a new one.
private struct GenerateView: View {
    @ObservedObject var store: ToolsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InputField(placeholder: "Your email, for +alias addresses", icon: "at", text: $store.baseEmail)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(TestData.generators) { generator in
                        ValueCard(title: generator.title, value: store.values[generator.title] ?? "",
                                  copied: store.copied == generator.title) {
                            store.copy(generator.title, value: store.values[generator.title] ?? "")
                        } onRefresh: {
                            store.regenerate(generator.title)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

private struct ValueCard: View {
    let title: String
    let value: String
    let copied: Bool
    let onCopy: () -> Void
    let onRefresh: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.caption(10.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
                Text(copied ? "Copied" : value)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(copied ? Theme.green : Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if hovering {
                IconButton(icon: "arrow.clockwise", help: "Another one", size: 10, action: onRefresh)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? Theme.cardHover : Theme.card))
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
        .onHover { hovering = $0 }
        .help("Click to copy: \(value)")
    }
}

/// Paste anything; every way it can be read shows up below, each one copyable.
private struct ConvertView: View {
    @ObservedObject var store: ToolsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.input)
                    .font(.system(size: 11.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if store.input.isEmpty {
                    Text("Paste a JWT, Base64, JSON, timestamp, date, URL…")
                        .font(Theme.caption(11.5, weight: .regular))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 70)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 2) {
                    IconButton(icon: "doc.on.clipboard", help: "Paste", size: 10, action: store.pasteInput)
                    if !store.input.isEmpty { IconButton(icon: "xmark", help: "Clear", size: 9) { store.input = "" } }
                }
                .padding(4)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Converters.all(store.input)) { result in
                        ResultCard(result: result, copied: store.copied == result.title) {
                            store.copy(result.title, value: result.value, refresh: false)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

private struct ResultCard: View {
    let result: Converters.Result
    let copied: Bool
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(result.title).font(Theme.caption(10.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
                Spacer()
                Text(copied ? "Copied" : "Click to copy")
                    .font(Theme.caption(10, weight: .medium))
                    .foregroundStyle(copied ? Theme.green : Theme.tertiary)
                    .opacity(copied || hovering ? 1 : 0)
            }
            Text(result.value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .lineLimit(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? Theme.cardHover : Theme.card))
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
        .onHover { hovering = $0 }
    }
}

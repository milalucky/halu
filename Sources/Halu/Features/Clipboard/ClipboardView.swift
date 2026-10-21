import SwiftUI

/// Clipboard and Shelf in one tab.
struct ClipboardTab: View {
    @ObservedObject var clipboard: ClipboardStore
    let shelf: ShelfStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $clipboard.mode) {
                ForEach(ClipboardStore.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch clipboard.mode {
            case .clipboard: ClipboardView(store: clipboard)
            case .shelf: ShelfView(store: shelf)
            }
        }
    }
}

struct ClipboardView: View {
    @ObservedObject var store: ClipboardStore
    @State private var query = ""

    private var history: [ClipEntry] {
        store.history.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var snippets: [Snippet] {
        store.snippets.filter {
            query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                InputField(placeholder: "Search copied text and snippets", icon: "magnifyingglass", text: $query)
                IconButton(icon: "plus", help: "New snippet", size: 12) {
                    withAnimation(.easeOut(duration: 0.2)) { store.snippetDraft = SnippetDraft() }
                }
            }

            if let draft = store.snippetDraft {
                SnippetEditor(draft: Binding(get: { store.snippetDraft ?? draft }, set: { store.snippetDraft = $0 })) { saved in
                    store.saveSnippet(id: saved.id, title: saved.title, text: saved.text)
                    withAnimation(.easeOut(duration: 0.2)) { store.snippetDraft = nil }
                } onCancel: {
                    withAnimation(.easeOut(duration: 0.2)) { store.snippetDraft = nil }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if snippets.isEmpty && history.isEmpty && store.snippetDraft == nil {
                EmptyState(icon: "doc.on.clipboard", title: query.isEmpty ? "Nothing copied yet" : "No matches",
                           subtitle: query.isEmpty ? "Text you copy shows up here. Star anything to keep it as a snippet." : "Try another word.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !snippets.isEmpty {
                            SmallCaps("Snippets")
                            ForEach(snippets) { snippet in
                                ClipRow(text: snippet.text, title: snippet.title.isEmpty ? nil : snippet.title,
                                        detail: nil, starred: true) {
                                    store.copy(snippet.text)
                                } actions: {
                                    IconButton(icon: "pencil", help: "Edit") {
                                        withAnimation(.easeOut(duration: 0.2)) { store.snippetDraft = SnippetDraft(snippet) }
                                    }
                                    IconButton(icon: "trash", help: "Delete snippet") {
                                        withAnimation { store.deleteSnippet(snippet) }
                                    }
                                }
                            }
                        }
                        if !history.isEmpty {
                            HStack {
                                SmallCaps("Recent")
                                Spacer()
                                Button("Clear") { withAnimation { store.clearHistory() } }
                                    .buttonStyle(.plain)
                                    .font(Theme.caption(11, weight: .medium))
                                    .foregroundStyle(Theme.tertiary)
                                    .padding(.top, 8)
                                    .padding(.trailing, 8)
                            }
                            ForEach(history) { entry in
                                ClipRow(text: entry.text, title: nil,
                                        detail: [entry.app, Fmt.ago(entry.copiedAt)].compactMap { $0 }.joined(separator: " · "),
                                        starred: false) {
                                    store.copy(entry.text)
                                } actions: {
                                    IconButton(icon: "star", help: "Keep as snippet") {
                                        withAnimation(.easeOut(duration: 0.2)) { store.snippetDraft = SnippetDraft(text: entry.text) }
                                    }
                                    IconButton(icon: "trash", help: "Remove") {
                                        withAnimation { store.remove(entry) }
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

struct SmallCaps: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.caption(10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.tertiary)
            .padding(.top, 8)
            .padding(.leading, 10)
            .padding(.bottom, 2)
    }
}

/// A row that copies on click and briefly confirms it.
private struct ClipRow<Actions: View>: View {
    let text: String
    let title: String?
    let detail: String?
    let starred: Bool
    let onCopy: () -> Void
    @ViewBuilder let actions: () -> Actions
    @State private var copied = false

    var body: some View {
        HoverRow { hovering in
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: starred ? "star.fill" : "text.alignleft")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(starred ? Theme.accent : Theme.tertiary)
                    .frame(width: 14)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    if let title {
                        Text(title).font(Theme.body(12.5, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                    }
                    Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(Theme.body(12.5))
                        .foregroundStyle(title == nil ? Theme.primary : Theme.secondary)
                        .lineLimit(2)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(Theme.caption(10.5, weight: .regular)).foregroundStyle(Theme.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if copied {
                    Text("Copied").font(Theme.caption(11, weight: .semibold)).foregroundStyle(Theme.green)
                        .transition(.opacity)
                } else if hovering {
                    actions()
                }
            }
        }
        .onTapGesture {
            onCopy()
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        }
    }
}

struct SnippetDraft: Equatable {
    var id: UUID?
    var title = ""
    var text = ""

    init(id: UUID? = nil, title: String = "", text: String = "") {
        self.id = id
        self.title = title
        self.text = text
    }

    init(_ snippet: Snippet) {
        self.init(id: snippet.id, title: snippet.title, text: snippet.text)
    }
}

private struct SnippetEditor: View {
    @Binding var draft: SnippetDraft
    let onSave: (SnippetDraft) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $draft.title, prompt: Text("Name (optional)").foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(Theme.body(12.5, weight: .semibold))
                .foregroundStyle(Theme.primary)
            TextField("", text: $draft.text, prompt: Text("Snippet text").foregroundStyle(Theme.tertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body(12.5))
                .foregroundStyle(Theme.primary)
                .lineLimit(2...5)
            HStack {
                Spacer()
                PillButton(title: "Cancel", tint: Theme.secondary, prominent: false, action: onCancel)
                PillButton(title: "Save", action: { onSave(draft) })
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
    }
}

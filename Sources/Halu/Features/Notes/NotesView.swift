import SwiftUI

struct NotesView: View {
    @ObservedObject var store: NotesStore
    @State private var query = ""

    private var filtered: [AppleNote] {
        store.notes.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.folder.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            switch store.access {
            case .denied:
                EmptyState(icon: "note.text", title: "Allow access to Notes",
                           subtitle: "Turn on Notes for Halu in Privacy & Security → Automation, then come back.",
                           action: ("Open Settings", store.openPrivacySettings))
            case .unknown where store.notes.isEmpty:
                EmptyState(icon: "note.text", title: "Loading Apple Notes…",
                           subtitle: "macOS may ask whether Halu can use Notes. Choose OK.")
            default:
                content
            }
        }
        .onAppear(perform: store.refresh)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    InputField(placeholder: "Search", icon: "magnifyingglass", text: $query)
                    IconButton(icon: "square.and.pencil", help: "New note", size: 12, action: store.startDraft)
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { note in
                            NoteListRow(note: note, selected: note.id == store.selectedID) {
                                store.select(note.id)
                            } onDelete: {
                                withAnimation { store.delete(note) }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .frame(width: 190)

            if store.isDraft || store.selectedID != nil {
                NoteEditor(store: store)
            } else {
                EmptyState(icon: "note.text", title: "Pick a note", subtitle: "Or start a new one; it's saved to Apple Notes as you type.",
                           action: ("New note", store.startDraft))
            }
        }
    }
}

private struct NoteListRow: View {
    let note: AppleNote
    let selected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .font(Theme.body(12.5, weight: .medium))
                .foregroundStyle(selected ? Theme.primary : Theme.secondary)
                .lineLimit(1)
            Text("\(note.folder) · \(Fmt.ago(note.modified))")
                .font(Theme.caption(10.5, weight: .regular))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.white.opacity(0.1) : (hovering ? Theme.card : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu { Button("Move to Recently Deleted", role: .destructive, action: onDelete) }
    }
}

private struct NoteEditor: View {
    @ObservedObject var store: NotesStore
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isRich {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 11))
                    Text("Has images, checklists or tables. Read-only here.")
                        .font(Theme.caption(11.5, weight: .medium))
                    Spacer()
                    PillButton(title: "Open in Notes", icon: "arrow.up.forward", prominent: false, action: store.openInNotes)
                }
                .foregroundStyle(Theme.secondary)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { store.body }, set: { store.edit($0) }))
                    .font(Theme.body(13.5))
                    .foregroundStyle(Theme.primary)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .disabled(store.isRich)
                    .focused($focused)
                if store.body.isEmpty && !store.isLoadingBody {
                    Text(store.isDraft ? "Start typing; the first line becomes the title" : "")
                        .font(Theme.body(13.5))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                if store.isLoadingBody {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        }
        .onChange(of: store.isDraft) { _, draft in if draft { focused = true } }
    }
}

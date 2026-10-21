import SwiftUI

struct NotesView: View {
    @ObservedObject var store: NotesStore

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: store.create) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil").font(.system(size: 11, weight: .semibold))
                        Text("New note").font(Theme.caption(12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.notes) { note in
                            NoteListRow(note: note, selected: note.id == store.selectedID) {
                                store.select(note.id)
                            } onDelete: {
                                withAnimation { store.delete(note.id) }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .frame(width: 150)

            if let note = store.selected {
                NoteEditor(note: note, store: store).id(note.id)
            } else {
                EmptyState(icon: "note.text", title: "No notes", subtitle: "Jot something down. Empty notes clean themselves up.",
                           action: ("New note", store.create))
            }
        }
    }
}

private struct NoteListRow: View {
    let note: Note
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
            Text(Fmt.ago(note.updatedAt))
                .font(Theme.caption(10.5, weight: .regular))
                .foregroundStyle(Theme.tertiary)
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
        .contextMenu { Button("Delete", role: .destructive, action: onDelete) }
    }
}

private struct NoteEditor: View {
    let note: Note
    let store: NotesStore
    @State private var text: String
    @FocusState private var focused: Bool

    init(note: Note, store: NotesStore) {
        self.note = note
        self.store = store
        _text = State(initialValue: note.text)
    }

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.body(13.5))
            .foregroundStyle(Theme.primary)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .focused($focused)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .onChange(of: text) { _, value in store.update(note.id, text: value) }
            .onAppear { if note.isBlank { focused = true } }
    }
}

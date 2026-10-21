import Foundation

struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var updatedAt: Date

    var title: String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "New note" : trimmed
    }

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A scratch pad. Blank notes disappear as soon as you leave them.
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [Note]
    @Published var selectedID: UUID?

    private let file = JSONFile<[Note]>("notes.json")
    private var saveWork: DispatchWorkItem?

    init() {
        notes = (file.load() ?? []).filter { !$0.isBlank }.sorted { $0.updatedAt > $1.updatedAt }
        selectedID = notes.first?.id
    }

    var selected: Note? { notes.first { $0.id == selectedID } }

    func create() {
        pruneBlank(except: nil)
        let note = Note(text: "", updatedAt: .now)
        notes.insert(note, at: 0)
        selectedID = note.id
    }

    func select(_ id: UUID) {
        pruneBlank(except: id)
        selectedID = id
    }

    func update(_ id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updatedAt = .now
        scheduleSave()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        if selectedID == id { selectedID = notes.first?.id }
        save()
    }

    private func pruneBlank(except keep: UUID?) {
        let before = notes.count
        notes.removeAll { $0.isBlank && $0.id != keep }
        if notes.count != before { save() }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func save() {
        file.save(notes.filter { !$0.isBlank })
    }
}

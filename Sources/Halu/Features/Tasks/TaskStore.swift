import Foundation

struct TaskItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var createdAt: Date
    var doneAt: Date?
}

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var items: [TaskItem]
    private let file = JSONFile<[TaskItem]>("tasks.json")

    init() {
        items = file.load() ?? []
    }

    var open: [TaskItem] { items.filter { $0.doneAt == nil } }
    var done: [TaskItem] {
        items.filter { $0.doneAt != nil }.sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(TaskItem(title: trimmed, createdAt: .now))
        save()
    }

    func complete(_ id: UUID) { update(id) { $0.doneAt = .now } }
    func restore(_ id: UUID) { update(id) { $0.doneAt = nil } }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = trimmed }
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    private func update(_ id: UUID, _ change: (inout TaskItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save()
    }

    private func save() { file.save(items) }
}

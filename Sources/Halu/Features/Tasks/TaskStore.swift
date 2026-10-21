import Foundation

struct TaskItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var createdAt: Date
    var doneAt: Date?
    /// Labels like a team or an area of work ("DTM", "Autotests").
    var tags: [String] = []

    init(title: String, createdAt: Date, tags: [String] = []) {
        self.title = title
        self.createdAt = createdAt
        self.tags = tags
    }

    // Tasks saved before tags existed have none.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        doneAt = try container.decodeIfPresent(Date.self, forKey: .doneAt)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var items: [TaskItem]
    /// The new-task field, kept here so it survives the panel closing.
    @Published var draft = ""
    /// The weekly recap is open in the Tasks tab.
    @Published var showingRecap = false
    /// Tags picked for the task being written.
    @Published var draftTags: [String] = []
    /// Show only tasks with this tag (nil = all); new tasks get it too.
    @Published var tagFilter: String? = UserDefaults.standard.string(forKey: "tasks.tagFilter") {
        didSet { UserDefaults.standard.set(tagFilter, forKey: "tasks.tagFilter") }
    }
    /// Tags offered in the picker, in the order they were made.
    @Published private(set) var tags: [String] = UserDefaults.standard.stringArray(forKey: "tasks.tags") ?? []
    private let file = JSONFile<[TaskItem]>("tasks.json")

    init() {
        items = file.load() ?? []
    }

    var open: [TaskItem] { items.filter { $0.doneAt == nil && matches($0) } }

    private func matches(_ task: TaskItem) -> Bool {
        tagFilter.map { filter in task.tags.contains { $0.caseInsensitiveCompare(filter) == .orderedSame } } ?? true
    }

    func openCount(_ tag: String) -> Int {
        items.filter { $0.doneAt == nil && $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }.count
    }
    var done: [TaskItem] {
        items.filter { $0.doneAt != nil }.sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    /// "#DTM fix login" makes a task "fix login" tagged DTM. Picked tags and the active filter are added.
    func add(_ title: String) {
        var words: [String] = []
        var tags = draftTags + (tagFilter.map { [$0] } ?? [])
        for word in title.split(separator: " ", omittingEmptySubsequences: true) {
            if word.hasPrefix("#"), word.count > 1 { tags.append(String(word.dropFirst())) } else { words.append(String(word)) }
        }
        let trimmed = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let unique = tags.reduce(into: [String]()) { list, tag in
            let tag = canonical(tag)
            if !list.contains(tag) { list.append(tag) }
        }
        unique.forEach(remember)
        items.append(TaskItem(title: trimmed, createdAt: .now, tags: unique))
        draftTags = []
        save()
    }

    func toggleDraftTag(_ tag: String) {
        if let index = draftTags.firstIndex(of: tag) { draftTags.remove(at: index) } else { draftTags.append(tag) }
    }

    func toggle(_ tag: String, on id: UUID) {
        update(id) { task in
            if let index = task.tags.firstIndex(of: tag) { task.tags.remove(at: index) } else { task.tags.append(tag) }
        }
    }

    /// Takes a tag off the picker; tasks keep it until it's removed from them.
    func forget(_ tag: String) {
        tags.removeAll { $0 == tag }
        if tagFilter == tag { tagFilter = nil }
        UserDefaults.standard.set(tags, forKey: "tasks.tags")
    }

    /// The spelling already in use ("dtm" → "DTM").
    private func canonical(_ tag: String) -> String {
        tags.first { $0.caseInsensitiveCompare(tag) == .orderedSame } ?? tag
    }

    private func remember(_ tag: String) {
        guard !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        tags.append(tag)
        UserDefaults.standard.set(tags, forKey: "tasks.tags")
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

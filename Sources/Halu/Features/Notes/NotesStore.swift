import AppKit

struct AppleNote: Identifiable, Equatable {
    let id: String
    var title: String
    var folder: String
    var modified: Date
}

/// The Notes tab is Apple Notes itself, driven through AppleScript. Plain-text notes are edited in
/// place; notes with images, checklists or tables open read-only, because writing them back
/// through AppleScript would flatten them.
@MainActor
final class NotesStore: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var notes: [AppleNote] = []
    @Published private(set) var access: Access = .unknown
    @Published private(set) var selectedID: String?
    @Published private(set) var body = ""
    @Published private(set) var isRich = false
    @Published private(set) var isLoadingBody = false

    /// A note typed in Halu that Notes hasn't created yet.
    @Published private(set) var isDraft = false

    private let bridge = NotesBridge()
    private var saveWork: DispatchWorkItem?
    private var pendingText: String?

    var selected: AppleNote? { notes.first { $0.id == selectedID } }

    func refresh() {
        bridge.listNotes { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let notes):
                self.access = .granted
                self.notes = notes.sorted { $0.modified > $1.modified }
                if self.selectedID == nil, !self.isDraft, let first = self.notes.first { self.select(first.id) }
            case .failure:
                self.access = .denied
            }
        }
    }

    func select(_ id: String) {
        flushSave()
        isDraft = false
        selectedID = id
        isLoadingBody = true
        bridge.content(of: id) { [weak self] result in
            guard let self, self.selectedID == id else { return }
            self.isLoadingBody = false
            if case .success(let content) = result {
                self.body = content.plainText
                self.isRich = content.isRich
            }
        }
    }

    func startDraft() {
        flushSave()
        selectedID = nil
        isDraft = true
        isRich = false
        body = ""
    }

    func edit(_ text: String) {
        guard !isRich else { return }
        body = text
        pendingText = text
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func delete(_ note: AppleNote) {
        bridge.delete(note.id) { [weak self] in
            guard let self else { return }
            self.notes.removeAll { $0.id == note.id }
            if self.selectedID == note.id {
                self.selectedID = nil
                self.body = ""
                if let first = self.notes.first { self.select(first.id) }
            }
        }
    }

    func openInNotes() {
        guard let id = selectedID else { return }
        bridge.show(id)
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func flushSave() {
        saveWork?.cancel()
        guard let text = pendingText else { return }
        pendingText = nil
        let html = Self.html(from: text)
        let title = text.split(separator: "\n").first.map(String.init) ?? "New Note"

        if isDraft {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            isDraft = false
            bridge.create(html: html) { [weak self] id in
                guard let self, let id else { return }
                self.notes.insert(AppleNote(id: id, title: title, folder: "Notes", modified: .now), at: 0)
                self.selectedID = id
            }
        } else if let id = selectedID {
            bridge.setBody(id, html: html)
            if let index = notes.firstIndex(where: { $0.id == id }) {
                notes[index].title = title
                notes[index].modified = .now
            }
        }
    }

    private static func html(from text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let escaped = line
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return escaped.isEmpty ? "<div><br></div>" : "<div>\(escaped)</div>"
        }.joined()
    }
}

/// Runs AppleScript against Notes on one background queue and hops results back to the main actor.
final class NotesBridge: @unchecked Sendable {
    struct Content {
        var plainText: String
        var isRich: Bool
    }

    private let queue = DispatchQueue(label: "halu.notes", qos: .userInitiated)
    private static let richMarkers = ["<img", "<table", "<ul", "<ol", "<object", "<hr"]

    func listNotes(_ done: @escaping @MainActor (Result<[AppleNote], Error>) -> Void) {
        let source = """
        tell application "Notes"
            set out to {}
            repeat with f in folders
                if name of f is not "Recently Deleted" then
                    set end of out to {name of f, id of notes of f, name of notes of f, modification date of notes of f}
                end if
            end repeat
            return out
        end tell
        """
        run(source) { result in
            done(result.map { descriptor in
                var notes: [AppleNote] = []
                for folderIndex in stride(from: 1, through: descriptor.numberOfItems, by: 1) {
                    guard let folder = descriptor.atIndex(folderIndex),
                          let name = folder.atIndex(1)?.stringValue,
                          let ids = folder.atIndex(2), let titles = folder.atIndex(3), let dates = folder.atIndex(4) else { continue }
                    for index in stride(from: 1, through: ids.numberOfItems, by: 1) {
                        guard let id = ids.atIndex(index)?.stringValue else { continue }
                        notes.append(AppleNote(id: id, title: titles.atIndex(index)?.stringValue ?? "Untitled",
                                               folder: name, modified: dates.atIndex(index)?.dateValue ?? .distantPast))
                    }
                }
                return notes
            })
        }
    }

    func content(of id: String, _ done: @escaping @MainActor (Result<Content, Error>) -> Void) {
        let source = """
        tell application "Notes"
            set n to note id "\(Self.escape(id))"
            return {body of n, plaintext of n}
        end tell
        """
        run(source) { result in
            done(result.map { descriptor in
                let html = descriptor.atIndex(1)?.stringValue ?? ""
                let plain = descriptor.atIndex(2)?.stringValue ?? ""
                return Content(plainText: plain, isRich: Self.richMarkers.contains { html.localizedCaseInsensitiveContains($0) })
            })
        }
    }

    func setBody(_ id: String, html: String) {
        run("tell application \"Notes\" to set body of note id \"\(Self.escape(id))\" to \"\(Self.escape(html))\"") { _ in }
    }

    func create(html: String, _ done: @escaping @MainActor (String?) -> Void) {
        let source = """
        tell application "Notes"
            set n to make new note at default folder of default account with properties {body:"\(Self.escape(html))"}
            return id of n
        end tell
        """
        run(source) { result in done(try? result.get().stringValue) }
    }

    func delete(_ id: String, _ done: @escaping @MainActor () -> Void) {
        run("tell application \"Notes\" to delete note id \"\(Self.escape(id))\"") { _ in done() }
    }

    func show(_ id: String) {
        run("tell application \"Notes\"\nshow note id \"\(Self.escape(id))\"\nactivate\nend tell") { _ in }
    }

    private func run(_ source: String, _ done: @escaping @MainActor (Result<NSAppleEventDescriptor, Error>) -> Void) {
        queue.async {
            var error: NSDictionary?
            let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let result: Result<NSAppleEventDescriptor, Error>
            if let output, error == nil {
                result = .success(output)
            } else {
                NSLog("Halu: Notes script failed: \(error ?? [:])")
                result = .failure(NSError(domain: "Halu.Notes", code: (error?[NSAppleScript.errorNumber] as? Int) ?? -1))
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

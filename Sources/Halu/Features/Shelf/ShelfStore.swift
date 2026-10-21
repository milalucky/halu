import AppKit
import UniformTypeIdentifiers

struct ShelfItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case image, video, file }
    enum Source: String, Codable { case screenshot, clipboard, dropped }

    var id = UUID()
    var url: URL
    var addedAt: Date
    var kind: Kind
    var source: Source

    static func kind(of url: URL) -> Kind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audiovisualContent) { return .video }
        return .file
    }
}

/// Files waiting to be dragged somewhere. New screenshots and screen recordings from the
/// system screenshot folder, and images copied to the clipboard, arrive on their own.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []

    let screenshotFolder: URL
    private let file = JSONFile<[ShelfItem]>("shelf.json")
    private let limit = 40
    private var source: DispatchSourceFileSystemObject?
    private var timers: [Timer] = []
    private var lastClipboardChange = NSPasteboard.general.changeCount
    private var ownClipboardChange = -1

    private var lastScan: Date? {
        get { UserDefaults.standard.object(forKey: "shelf.lastScan") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "shelf.lastScan") }
    }

    private static var clipboardFolder: URL {
        let url = HaluStorage.directory.appendingPathComponent("Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() {
        let configured = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let path = (configured.map { ($0 as NSString).expandingTildeInPath }) ?? ("~/Desktop" as NSString).expandingTildeInPath
        screenshotFolder = URL(fileURLWithPath: path, isDirectory: true)
    }

    func start() {
        let manager = FileManager.default
        items = (file.load() ?? []).filter { manager.fileExists(atPath: $0.url.path) }
        scanScreenshots()
        watchScreenshotFolder()

        let clipboard = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollClipboard() }
        }
        let fallback = Timer(timeInterval: 6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanScreenshots() }
        }
        for timer in [clipboard, fallback] { RunLoop.main.add(timer, forMode: .common) }
        timers = [clipboard, fallback]
    }

    // MARK: Editing

    func add(urls: [URL], source: ShelfItem.Source = .dropped) {
        for url in urls {
            items.removeAll { $0.url == url }
            items.insert(ShelfItem(url: url, addedAt: .now, kind: ShelfItem.kind(of: url), source: source), at: 0)
        }
        trim()
        save()
    }

    func add(providers: [NSItemProvider]) {
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { self?.add(urls: [url]) }
            }
        }
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        deleteIfOwned(item)
        save()
    }

    func clear() {
        items.forEach(deleteIfOwned)
        items.removeAll()
        save()
    }

    func copy(_ item: ShelfItem) {
        let board = NSPasteboard.general
        board.clearContents()
        var objects: [NSPasteboardWriting] = [item.url as NSURL]
        if item.kind == .image, let image = NSImage(contentsOf: item.url) { objects.append(image) }
        board.writeObjects(objects)
        ownClipboardChange = board.changeCount
    }

    func open(_ item: ShelfItem) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: ShelfItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    // MARK: Sources

    private func watchScreenshotFolder() {
        let descriptor = Darwin.open(screenshotFolder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            // The screenshot tool writes a hidden temp file first and renames it a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.scanScreenshots() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func scanScreenshots() {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: screenshotFolder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return }
        let media = files.compactMap { url -> (URL, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let created = values.creationDate, ShelfItem.kind(of: url) != .file else { return nil }
            return (url, created)
        }
        // First run: bring in the latest few so the shelf isn't empty.
        let since = lastScan ?? Date().addingTimeInterval(-2 * 86400)
        var fresh = media.filter { $0.1 > since }.sorted { $0.1 < $1.1 }
        if lastScan == nil { fresh = Array(fresh.suffix(8)) }
        guard !fresh.isEmpty || lastScan == nil else { return }

        let known = Set(items.map(\.url))
        for (url, _) in fresh where !known.contains(url) {
            items.insert(ShelfItem(url: url, addedAt: .now, kind: ShelfItem.kind(of: url), source: .screenshot), at: 0)
        }
        lastScan = max(lastScan ?? .distantPast, fresh.last?.1 ?? Date())
        trim()
        save()
    }

    private func pollClipboard() {
        let board = NSPasteboard.general
        guard board.changeCount != lastClipboardChange else { return }
        lastClipboardChange = board.changeCount
        guard board.changeCount != ownClipboardChange else { return }
        let types = board.types ?? []
        guard !types.contains(.fileURL), types.contains(.png) || types.contains(.tiff) else { return }

        let png = board.data(forType: .png)
            ?? board.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        guard let png else { return }
        let name = "Clipboard \(Self.stamp.string(from: .now)).png"
        let url = Self.clipboardFolder.appendingPathComponent(name)
        guard (try? png.write(to: url)) != nil else { return }
        add(urls: [url], source: .clipboard)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    // MARK: Housekeeping

    private func trim() {
        guard items.count > limit else { return }
        items[limit...].forEach(deleteIfOwned)
        items = Array(items.prefix(limit))
    }

    /// Only images Halu saved from the clipboard are deleted; everything else stays where it is.
    private func deleteIfOwned(_ item: ShelfItem) {
        guard item.source == .clipboard, item.url.path.hasPrefix(Self.clipboardFolder.path) else { return }
        try? FileManager.default.removeItem(at: item.url)
    }

    private func save() { file.save(items) }
}

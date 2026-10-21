import AppKit
import SQLite3

struct IncomingMessage: Identifiable, Equatable {
    var id: Int64
    var appID: String
    var appName: String
    var title: String
    var subtitle: String
    var body: String
    var date: Date
}

/// New messages from Slack, Telegram, other messengers and mail apps, read from the notifications macOS already
/// received for them. No tokens or sign-in needed; it takes Full Disk Access, because the notification
/// database is protected.
@MainActor
final class MessagesStore: ObservableObject {
    enum Access { case unknown, granted, needsFullDiskAccess, unreadable }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var messages: [IncomingMessage] = []
    @Published var appFilter: String?
    @Published private(set) var unseen = 0

    /// Messenger bundle ids and the names shown for them.
    nonisolated static let messengers: [String: String] = [
        "com.tinyspeck.slackmacgap": "Slack",
        "ru.keepcoder.Telegram": "Telegram",
        "org.telegram.desktop": "Telegram",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "desktop.WhatsApp": "WhatsApp",
        "com.apple.MobileSMS": "Messages",
        "com.microsoft.teams2": "Teams",
        "com.hnc.Discord": "Discord",
        "Mattermost.Desktop": "Mattermost",
        // Work mail.
        "com.apple.mail": "Mail",
        "com.microsoft.Outlook": "Outlook",
        "com.readdle.SparkDesktop": "Spark",
        "com.readdle.SparkDesktop.appstore": "Spark",
    ]

    /// How far back "new" reaches.
    private let window: TimeInterval = 24 * 3600
    private var lastSeen = UserDefaults.standard.object(forKey: "messages.lastSeen") as? Date ?? .distantPast
    private var dismissed = Set(UserDefaults.standard.array(forKey: "messages.dismissed") as? [Int64] ?? [])
    private var timer: Timer?
    private let queue = DispatchQueue(label: "halu.messages", qos: .utility)

    private nonisolated static var databasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path
    }

    var apps: [String] { Array(Set(messages.map(\.appName))).sorted() }

    var visible: [IncomingMessage] {
        messages.filter { appFilter == nil || $0.appName == appFilter }
    }

    func isNew(_ message: IncomingMessage) -> Bool { message.date > lastSeen }

    /// Apps with unread messages, most recent first; drives the icons on the collapsed notch.
    var unseenApps: [String] {
        var apps: [String] = []
        for message in messages where message.date > lastSeen && !apps.contains(message.appID) {
            apps.append(message.appID)
        }
        return apps
    }

    func start() {
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        reload()
    }

    func reload() {
        guard FileManager.default.isReadableFile(atPath: Self.databasePath) else {
            access = .needsFullDiskAccess
            return
        }
        let since = Date().addingTimeInterval(-window)
        queue.async {
            let result = Self.read(since: since)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let found = result else {
                        self.access = .unreadable
                        return
                    }
                    self.access = .granted
                    let fresh = found.filter { !self.dismissed.contains($0.id) }
                    if fresh != self.messages { self.messages = fresh }
                    self.unseen = fresh.filter { $0.date > self.lastSeen }.count
                }
            }
        }
    }

    /// Called while the Messages tab is on screen.
    func markSeen() {
        lastSeen = messages.first?.date ?? .now
        UserDefaults.standard.set(lastSeen, forKey: "messages.lastSeen")
        unseen = 0
    }

    func dismiss(_ message: IncomingMessage) {
        dismissed.insert(message.id)
        messages.removeAll { $0.id == message.id }
        saveDismissed()
    }

    func dismissAll() {
        visible.forEach { dismissed.insert($0.id) }
        messages.removeAll { appFilter == nil || $0.appName == appFilter }
        saveDismissed()
    }

    func open(_ message: IncomingMessage) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: message.appID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func icon(for appID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private func saveDismissed() {
        // Only ids still in the window are worth remembering.
        let live = Set(messages.map(\.id)).union(dismissed.suffix(500))
        dismissed = dismissed.intersection(live)
        UserDefaults.standard.set(Array(dismissed), forKey: "messages.dismissed")
    }

    // MARK: Notification database

    private nonisolated static func read(since: Date) -> [IncomingMessage]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let ids = messengers.keys.map { "'\($0)'" }.joined(separator: ",")
        let sql = """
        SELECT r.rec_id, a.identifier, r.data, r.delivered_date
        FROM record r JOIN app a ON a.app_id = r.app_id
        WHERE a.identifier IN (\(ids)) AND r.delivered_date > ?
        ORDER BY r.delivered_date DESC LIMIT 200
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSinceReferenceDate)

        var found: [IncomingMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            guard let rawID = sqlite3_column_text(statement, 1), let blob = sqlite3_column_blob(statement, 2) else { continue }
            let appID = String(cString: rawID)
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 2)))
            let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3))
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let request = plist["req"] as? [String: Any] else { continue }
            let title = request["titl"] as? String ?? ""
            let body = request["body"] as? String ?? ""
            guard !title.isEmpty || !body.isEmpty else { continue }
            found.append(IncomingMessage(id: id, appID: appID, appName: messengers[appID] ?? appID,
                                         title: title, subtitle: request["subt"] as? String ?? "", body: body, date: date))
        }
        return found
    }
}

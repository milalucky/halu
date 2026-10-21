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
    /// Set for messages from a web app (Gmail, Telegram Web): opened in the browser.
    var url: URL?
}

/// Unread messages from Slack, Telegram, mail and other messengers, read from the notifications macOS
/// received for them. A message counts as read once you've been in its app or its site's browser tab
/// after it arrived (web apps never clear their notifications), or once its notification is gone. Web apps in a browser (Gmail, Telegram
/// Web, Slack in the browser) are recognised by their site. No tokens or sign-in; it takes Full Disk
/// Access, because the notification database is protected.
@MainActor
final class MessagesStore: ObservableObject {
    /// False while the tab is turned off in Settings: background work pauses.
    var isActive: () -> Bool = { true }

    enum Access { case unknown, granted, needsFullDiskAccess, unreadable }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var messages: [IncomingMessage] = []
    @Published var appFilter: String?
    /// Unread messages still waiting; drives the sidebar dot and the notch indicators.
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

    /// Browsers whose notifications may come from a web messenger or web mail.
    nonisolated static let browsers = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "ru.yandex.desktop.yandex-browser",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.operasoftware.Opera", "com.brave.Browser",
    ]

    /// Sites recognised in browser notifications: name and the page to open.
    nonisolated static let webApps: [(site: String, name: String, url: String)] = [
        ("mail.google.com", "Gmail", "https://mail.google.com"),
        ("web.telegram.org", "Telegram", "https://web.telegram.org"),
        ("app.slack.com", "Slack", "https://app.slack.com"),
        ("outlook.office.com", "Outlook", "https://outlook.office.com/mail"),
        ("outlook.live.com", "Outlook", "https://outlook.live.com/mail"),
        ("web.whatsapp.com", "WhatsApp", "https://web.whatsapp.com"),
    ]

    /// Older notifications are not "waiting" any more, even if never cleared.
    private let window: TimeInterval = 7 * 24 * 3600
    private var dismissed = Set(UserDefaults.standard.array(forKey: "messages.dismissed") as? [Int64] ?? [])
    /// When each source (by name) was last in front: its app, or its site in the browser's active tab.
    private var visits: [String: Date] = UserDefaults.standard.dictionary(forKey: "messages.visits") as? [String: Date] ?? [:]
    private var visitTimer: Timer?
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

    /// Sources with unread messages, most recent first (their names); drives the notch icons.
    var unseenApps: [String] {
        var apps: [String] = []
        for message in messages where !apps.contains(message.appName) { apps.append(message.appName) }
        return apps
    }

    func start() {
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let visitTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackVisit() }
        }
        RunLoop.main.add(visitTimer, forMode: .common)
        self.visitTimer = visitTimer
        reload()
    }

    /// Notes which source is in front right now, so its earlier messages count as read.
    private func trackVisit() {
        guard isActive(), let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier else { return }
        if let name = Self.messengers[bundleID] {
            markVisited(name)
        } else if Self.browsers.contains(bundleID) {
            queue.async {
                let host = Self.activeTabHost(bundleID)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let host, let web = Self.webApps.first(where: { host.hasSuffix($0.site) }) else { return }
                        self.markVisited(web.name)
                    }
                }
            }
        }
    }

    private func markVisited(_ name: String) {
        visits[name] = Date()
        UserDefaults.standard.set(visits, forKey: "messages.visits")
        let before = messages.count
        messages.removeAll { $0.appName == name && $0.date <= visits[name]! }
        if messages.count != before { unseen = messages.count }
    }

    private nonisolated static func activeTabHost(_ bundleID: String) -> String? {
        let property = bundleID == "com.apple.Safari" ? "URL of front document" : "URL of active tab of front window"
        var error: NSDictionary?
        let output = NSAppleScript(source: "tell application id \"\(bundleID)\" to get \(property)")?.executeAndReturnError(&error)
        return output?.stringValue.flatMap { URL(string: $0)?.host?.lowercased() }
    }

    func reload() {
        guard isActive() else { return }
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
                    let fresh = found.filter { message in
                        !self.dismissed.contains(message.id) && message.date > (self.visits[message.appName] ?? .distantPast)
                    }
                    if fresh != self.messages { self.messages = fresh }
                    self.unseen = fresh.count
                }
            }
        }
    }

    func dismiss(_ message: IncomingMessage) {
        dismissed.insert(message.id)
        messages.removeAll { $0.id == message.id }
        unseen = messages.count
        saveDismissed()
    }

    func dismissAll() {
        visible.forEach { dismissed.insert($0.id) }
        Set(visible.map(\.appName)).forEach { visits[$0] = Date() }
        UserDefaults.standard.set(visits, forKey: "messages.visits")
        messages.removeAll { appFilter == nil || $0.appName == appFilter }
        unseen = messages.count
        saveDismissed()
    }

    func open(_ message: IncomingMessage) {
        if let page = message.url {
            NSWorkspace.shared.open(page)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: message.appID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Icon of a source by name: the app's own icon when installed, a symbol for web apps.
    func icon(forSource name: String) -> NSImage? {
        if let message = messages.first(where: { $0.appName == name }), message.url == nil {
            return icon(for: message.appID)
        }
        let symbol = name == "Gmail" || name == "Outlook" ? "envelope.fill" : "bubble.left.fill"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: name)
    }

    func icon(for message: IncomingMessage) -> NSImage? {
        message.url == nil ? icon(for: message.appID) : icon(forSource: message.appName)
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

        let sql = """
        SELECT r.rec_id, a.identifier, r.data, r.delivered_date
        FROM record r JOIN app a ON a.app_id = r.app_id
        WHERE r.delivered_date > ?
        ORDER BY r.delivered_date DESC LIMIT 400
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
            let subtitle = request["subt"] as? String ?? ""
            let body = request["body"] as? String ?? ""
            guard !title.isEmpty || !body.isEmpty else { continue }

            var name = messengers[appID]
            var page: URL?
            var shownSubtitle = subtitle
            if name == nil, browsers.contains(where: { appID.hasPrefix($0) }) {
                // Browsers put the site in the subtitle or title, e.g. "mail.google.com".
                let haystack = "\(subtitle) \(title) \(body)".lowercased()
                if let web = webApps.first(where: { haystack.contains($0.site) }) {
                    name = web.name
                    page = URL(string: web.url)
                    if subtitle.lowercased().contains(web.site) { shownSubtitle = "" }
                }
            }
            guard let name else { continue }
            found.append(IncomingMessage(id: id, appID: appID, appName: name, title: title, subtitle: shownSubtitle,
                                         body: body, date: date, url: page))
        }
        return found
    }
}

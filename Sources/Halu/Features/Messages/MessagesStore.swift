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
    /// Set for unread state read from an open browser tab; opening switches to that tab.
    var web: WebInbox.Item?
    /// A direct message or a mention.
    var isPersonal = false
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
    /// Sites read from an open browser tab and what they're signed in as (Gmail addresses, Slack workspace).
    @Published private(set) var webAccounts: [String: [String]] = [:]
    /// Telegram chat folders found in the Telegram Web tab, and the one Messages follows ("" = all chats).
    @Published private(set) var telegramFolders: [String] = []
    @Published var telegramFolder = UserDefaults.standard.string(forKey: "messages.telegramFolder") ?? "" {
        didSet {
            UserDefaults.standard.set(telegramFolder, forKey: "messages.telegramFolder")
            web.removeAll { $0.appName == "Telegram" }
            merge()
            readWebTabs()
        }
    }
    /// The Gmail inbox Messages follows ("" = every open inbox).
    @Published var gmailAccount = UserDefaults.standard.string(forKey: "messages.gmailAccount") ?? "" {
        didSet {
            UserDefaults.standard.set(gmailAccount, forKey: "messages.gmailAccount")
            merge()
        }
    }
    /// Slack: only direct messages and mentions, or every unread channel.
    @Published var slackOnlyPersonal = UserDefaults.standard.bool(forKey: "messages.slackOnlyPersonal") {
        didSet {
            UserDefaults.standard.set(slackOnlyPersonal, forKey: "messages.slackOnlyPersonal")
            merge()
        }
    }

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
    private var notifications: [IncomingMessage] = []
    /// Unread conversations read from open Slack, Gmail and Telegram tabs, and the sites those tabs cover.
    private var web: [IncomingMessage] = []
    private var webCovered: Set<String> = []
    /// When each site last answered; a site that misses one read keeps its list for a while.
    private var webAnswered: [String: Date] = [:]
    private let webInbox = WebInbox()
    private var webTimer: Timer?
    private var webRetry: DispatchWorkItem?
    /// When each web item was first seen, so the list has a sensible order and "x min ago".
    private var firstSeen: [String: Date] = UserDefaults.standard.dictionary(forKey: "messages.firstSeen") as? [String: Date] ?? [:]
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
        let webTimer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readWebTabs() }
        }
        RunLoop.main.add(webTimer, forMode: .common)
        self.webTimer = webTimer
        reload()
        readWebTabs()
    }

    /// Reads unread state from Slack, Gmail and Telegram tabs in the running Chromium browsers.
    func readWebTabs() {
        guard isActive() else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let browsers = BrowserMedia.chromium.filter(running.contains)
        guard !browsers.isEmpty else {
            web = []
            webCovered = []
            webAccounts = [:]
            merge()
            return
        }
        webInbox.read(browsers: Array(browsers), telegramFolder: telegramFolder) { [weak self] snapshot in
            self?.apply(snapshot)
        }
    }

    private func apply(_ snapshot: WebInbox.Snapshot) {
        let now = Date()
        var answered = Set(snapshot.covered.subtracting(snapshot.pending).map(\.rawValue))
        for site in answered { webAnswered[site] = now }
        // A tab that's slow, loading or asleep for one read keeps what it showed, for up to two minutes.
        let holding = Set(webAnswered.filter { !answered.contains($0.key) && now.timeIntervalSince($0.value) < 120 }.keys)
        var seen = firstSeen.filter { key, _ in snapshot.items.contains { $0.key == key } || web.contains { $0.web?.key == key } }
        let fresh = snapshot.items.map { item -> IncomingMessage in
            let first = seen[item.key] ?? now
            seen[item.key] = first
            var message = IncomingMessage(id: Self.stableID(item.key), appID: item.bundleID, appName: item.site.rawValue,
                                          title: item.title, subtitle: item.site == .gmail ? item.account : item.detail,
                                          body: item.text.isEmpty ? item.detail : item.text, date: item.date ?? first,
                                          url: nil, web: item, isPersonal: item.isPersonal)
            if item.text.isEmpty {
                // A notification for the same conversation tells what was said.
                let plain = item.title.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                if let preview = notifications.first(where: { $0.appName == item.site.rawValue && $0.title.contains(plain) }) {
                    message.body = preview.body
                    message.date = max(message.date, preview.date)
                }
            }
            return message
        }
        web = fresh.filter { answered.contains($0.appName) } + web.filter { holding.contains($0.appName) }
        firstSeen = seen
        UserDefaults.standard.set(seen, forKey: "messages.firstSeen")
        webCovered = Set(snapshot.covered.map(\.rawValue)).union(holding)
        var accounts = webAccounts.filter { holding.contains($0.key) }
        for site in snapshot.covered { accounts[site.rawValue] = snapshot.accounts[site] ?? webAccounts[site.rawValue] ?? [] }
        if accounts != webAccounts { webAccounts = accounts }
        if snapshot.covered.contains(.telegram), !snapshot.telegramFolders.isEmpty, snapshot.telegramFolders != telegramFolders {
            telegramFolders = snapshot.telegramFolders
        }
        merge()
        // A tab read for the first time has its answer a moment later.
        if snapshot.pending.contains(where: { webAnswered[$0.rawValue] == nil }), webRetry == nil {
            webRetry = DispatchWorkItem { [weak self] in
                self?.webRetry = nil
                self?.readWebTabs()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: webRetry!)
        }
    }

    /// Gmail inboxes seen in open tabs.
    var gmailAccounts: [String] { webAccounts["Gmail"] ?? [] }

    private static func stableID(_ key: String) -> Int64 {
        // FNV-1a, kept positive and above notification record ids.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int64(hash >> 2) | (1 << 60)
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
        let before = notifications.count
        notifications.removeAll { $0.appName == name && $0.date <= visits[name]! }
        if notifications.count != before { merge() }
    }

    /// One list, newest first: an open browser tab wins over notifications for its service.
    private func merge() {
        let fromWeb = web.filter { message in
            guard !dismissed.contains(message.id) else { return false }
            if message.appName == "Gmail", !gmailAccount.isEmpty, message.web?.account != gmailAccount { return false }
            if message.appName == "Slack", slackOnlyPersonal, !message.isPersonal { return false }
            return true
        }
        let fromNotifications = notifications.filter { !webCovered.contains($0.appName) }
        let combined = (fromNotifications + fromWeb).sorted { $0.date > $1.date }
        if combined != messages { messages = combined }
        unseen = combined.count
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
                    self.notifications = found.filter { message in
                        !self.dismissed.contains(message.id) && message.date > (self.visits[message.appName] ?? .distantPast)
                    }
                    self.merge()
                }
            }
        }
    }

    func dismiss(_ message: IncomingMessage) {
        dismissed.insert(message.id)
        notifications.removeAll { $0.id == message.id }
        merge()
        saveDismissed()
    }

    func dismissAll() {
        visible.forEach { dismissed.insert($0.id) }
        Set(visible.map(\.appName)).forEach { visits[$0] = Date() }
        UserDefaults.standard.set(visits, forKey: "messages.visits")
        notifications.removeAll { appFilter == nil || $0.appName == appFilter }
        merge()
        saveDismissed()
    }

    func open(_ message: IncomingMessage) {
        if let item = message.web {
            webInbox.open(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.readWebTabs() }
        } else if let page = message.url {
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
        if let message = messages.first(where: { $0.appName == name }), message.url == nil, message.web == nil {
            return icon(for: message.appID)
        }
        // A web app whose desktop app is installed borrows that app's icon.
        for (bundleID, appName) in Self.messengers where appName == name {
            if let image = icon(for: bundleID) { return image }
        }
        let symbol = name == "Gmail" || name == "Outlook" ? "envelope.fill" : "bubble.left.fill"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: name)
    }

    func icon(for message: IncomingMessage) -> NSImage? {
        message.url == nil && message.web == nil ? icon(for: message.appID) : icon(forSource: message.appName)
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

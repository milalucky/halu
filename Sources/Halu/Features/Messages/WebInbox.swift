import Foundation

/// Unread state read straight from open browser tabs of Slack, Gmail and Telegram Web, the way each
/// site marks it itself (bold Slack channels, unread Gmail rows, Telegram badges). Tabs can sit in the
/// background. Needs "Allow JavaScript from Apple Events" in the browser, same as the Media tab.
/// Slack keeps only what's addressed to you (direct messages and channels with a mention badge,
/// which includes @channel and @here); Telegram only the chosen chat folder.
final class WebInbox: @unchecked Sendable {
    enum Site: String, CaseIterable {
        case slack = "Slack", gmail = "Gmail", telegram = "Telegram"

        var host: String {
            switch self {
            case .slack: "app.slack.com"
            case .gmail: "mail.google.com"
            case .telegram: "web.telegram.org"
            }
        }
    }

    struct Item: Sendable, Equatable {
        var site: Site
        var key: String
        var title: String
        var detail: String
        /// Which inbox or workspace it came from, e.g. the Gmail address.
        var account = ""
        /// Where it lives, to switch to it: browser, window and tab index, and an element to click.
        var bundleID: String
        var window: Int
        var tab: Int
        var click: String?
        var url: String?
    }

    struct Snapshot: Sendable {
        var items: [Item]
        /// Sites that have a tab open: their notifications are replaced by `items`.
        var covered: Set<Site>
        /// What each covered site is signed in as (Gmail addresses, Slack workspace), for Settings.
        var accounts: [Site: [String]] = [:]
        /// Telegram chat folders, in their order ("All" first).
        var telegramFolders: [String] = []
    }

    private let queue = DispatchQueue(label: "halu.web-inbox", qos: .utility)

    private static let scripts: [Site: String] = [
        .slack: """
        JSON.stringify({ team: ((document.querySelector('.p-ia4_home_header_menu__team_name') || {}).textContent || '').trim(),
          items: [...document.querySelectorAll('.p-channel_sidebar__channel--unread')].map(e => ({
            id: e.getAttribute('data-qa-channel-sidebar-channel-id') || '',
            name: ((e.querySelector('.p-channel_sidebar__name') || {}).textContent || '').trim(),
            type: e.getAttribute('data-qa-channel-sidebar-channel-type') || '',
            badge: ((e.querySelector('.p-channel_sidebar__badge') || {}).textContent || '').trim() })) })
        """,
        .gmail: """
        JSON.stringify({ account: (location.pathname.match(/\\/u\\/(\\d+)/) || [])[1] || '0',
          email: (document.title.match(/ - ([^\\s]+@[^\\s]+) - /) || [])[1] || '',
          items: [...document.querySelectorAll('tr.zA.zE')].slice(0, 30).map(r => {
            const from = r.querySelector('.yW span[email]'); const thread = r.querySelector('[data-legacy-thread-id]');
            return { id: thread ? thread.getAttribute('data-legacy-thread-id') : '',
              name: from ? (from.getAttribute('name') || from.textContent) : '',
              subject: ((r.querySelector('.bog') || {}).textContent || '').trim() }; }) })
        """,
    ]

    /// Telegram Web K: the chosen folder's unread chats. Only the open folder's list is in the page, so
    /// for another folder all we get is its badge, the number of unread chats in it.
    private static func telegramScript(folder: String) -> String {
        let wanted = (try? String(data: JSONSerialization.data(withJSONObject: [folder.lowercased()]), encoding: .utf8)) ?? "[\"\"]"
        return """
        (() => { const want = \(wanted)[0];
          const tabs = [...document.querySelectorAll('#folders-tabs .menu-horizontal-div-item')];
          const folders = tabs.map(e => { const c = e.cloneNode(true); c.querySelectorAll('.badge').forEach(b => b.remove());
            return { name: c.textContent.trim(), badge: ((e.querySelector('.badge') || {}).textContent || '').trim() }; });
          const index = want ? folders.findIndex(f => f.name.toLowerCase() === want) : -1;
          const lists = document.querySelectorAll('#folders-container > .tabs-tab');
          const scope = index >= 0 ? lists[index] : (lists[0] || document);
          const chats = scope ? [...scope.querySelectorAll('.chatlist-chat')] : [];
          const unread = c => c.querySelector('.badge-unread, .dialog-subtitle-badge-unread');
          return JSON.stringify({ folders: folders.map(f => f.name), folder: index >= 0 ? folders[index].name : '',
            folderIndex: index, folderBadge: index >= 0 ? folders[index].badge : '', rendered: chats.length > 0,
            items: chats.filter(unread).slice(0, 30).map(c => ({
              id: c.getAttribute('data-peer-id') || '',
              name: ((c.querySelector('.peer-title') || {}).textContent || '').trim(),
              badge: (unread(c).textContent || '').trim() })) }); })()
        """
    }

    func read(browsers: [String], telegramFolder: String, _ done: @escaping @MainActor (Snapshot) -> Void) {
        queue.async {
            var snapshot = Snapshot(items: [], covered: [])
            var scripts = Self.scripts
            scripts[.telegram] = Self.telegramScript(folder: telegramFolder)
            for browser in browsers { Self.scan(browser, scripts: scripts, into: &snapshot) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(snapshot) } }
        }
    }

    /// Brings the item's tab to the front and opens the channel, chat or thread in it.
    func open(_ item: Item) {
        queue.async {
            var lines = [
                "tell application id \"\(item.bundleID)\"",
                "set theWindow to window \(item.window)",
                "set active tab index of theWindow to \(item.tab)",
                "set index of theWindow to 1",
                "activate",
            ]
            if let click = item.click {
                lines.append("execute active tab of theWindow javascript \"\(Self.escape(click))\"")
            } else if let url = item.url {
                lines.append("set URL of active tab of theWindow to \"\(Self.escape(url))\"")
            }
            lines.append("end tell")
            var error: NSDictionary?
            NSAppleScript(source: lines.joined(separator: "\n"))?.executeAndReturnError(&error)
        }
    }

    // MARK: Reading

    private static func scan(_ browser: String, scripts: [Site: String], into snapshot: inout Snapshot) {
        // One script: walk every tab, run the site's script only where the URL matches.
        var source = "tell application id \"\(browser)\"\nset out to \"\"\nset wi to 0\nrepeat with w in windows\nset wi to wi + 1\nset ti to 0\nrepeat with t in tabs of w\nset ti to ti + 1\nset u to URL of t\n"
        for site in Site.allCases {
            source += "if u contains \"\(site.host)\" then set out to out & \"\(site.rawValue)\" & \"\\t\" & wi & \"\\t\" & ti & \"\\t\" & (execute t javascript \"\(escape(scripts[site]!))\") & linefeed\n"
        }
        source += "end repeat\nend repeat\nreturn out\nend tell"
        var error: NSDictionary?
        guard let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue, error == nil else { return }

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 3).map(String.init)
            guard parts.count == 4, let site = Site(rawValue: parts[0]), let window = Int(parts[1]), let tab = Int(parts[2]),
                  let json = try? JSONSerialization.jsonObject(with: Data(parts[3].utf8)) as? [String: Any],
                  let rows = json["items"] as? [[String: Any]] else { continue }
            snapshot.covered.insert(site)
            let account: String
            switch site {
            case .slack: account = json["team"] as? String ?? ""
            case .gmail: account = json["email"] as? String ?? ""
            case .telegram: account = json["folder"] as? String ?? ""
            }
            if !account.isEmpty, !(snapshot.accounts[site] ?? []).contains(account) { snapshot.accounts[site, default: []].append(account) }
            if site == .telegram {
                if let folders = json["folders"] as? [String], !folders.isEmpty { snapshot.telegramFolders = folders }
                // Another folder is open in the tab: one line with how many chats are unread in ours.
                if json["rendered"] as? Bool == false, let index = json["folderIndex"] as? Int, index >= 0 {
                    let badge = json["folderBadge"] as? String ?? ""
                    if !badge.isEmpty {
                        var item = Item(site: site, key: "Telegram:folder:\(account)", title: account.capitalized,
                                        detail: "\(badge) unread chat\(badge == "1" ? "" : "s")", account: account,
                                        bundleID: browser, window: window, tab: tab)
                        item.click = "(() => { const e = document.querySelectorAll('#folders-tabs .menu-horizontal-div-item')[\(index)]; if (e) e.click(); })()"
                        snapshot.items.append(item)
                    }
                    continue
                }
            }
            for row in rows {
                let id = row["id"] as? String ?? ""
                let name = row["name"] as? String ?? ""
                guard !id.isEmpty || !name.isEmpty else { continue }
                var item = Item(site: site, key: "\(site.rawValue):\(id.isEmpty ? name : id)", title: name, detail: "",
                                account: account, bundleID: browser, window: window, tab: tab)
                switch site {
                case .slack:
                    let badge = row["badge"] as? String ?? ""
                    let type = row["type"] as? String ?? ""
                    let isDirect = type == "im" || type == "mpim"
                    // Channels without a mention badge are just chatter.
                    guard isDirect || !badge.isEmpty else { continue }
                    item.title = isDirect ? name : "#\(name)"
                    item.detail = isDirect ? (badge.isEmpty ? "Direct message" : "\(badge) new")
                                           : "Mentioned you" + (badge == "1" ? "" : " · \(badge)")
                    item.click = "(() => { const e = document.querySelector('[data-qa-channel-sidebar-channel-id=\"\(id)\"]'); if (e) e.click(); })()"
                case .gmail:
                    item.detail = (row["subject"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(no subject)"
                    let account = json["account"] as? String ?? "0"
                    if !id.isEmpty { item.url = "https://mail.google.com/mail/u/\(account)/#inbox/\(id)" }
                case .telegram:
                    let badge = row["badge"] as? String ?? ""
                    item.detail = badge.isEmpty ? "Unread messages" : "\(badge) unread"
                    item.click = "(() => { const e = document.querySelector('.chatlist-chat[data-peer-id=\"\(id)\"]'); if (e) e.dispatchEvent(new MouseEvent('mousedown', { bubbles: true })); })()"
                }
                // The same conversation can show in two tabs; keep the first.
                if !snapshot.items.contains(where: { $0.key == item.key }) { snapshot.items.append(item) }
            }
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

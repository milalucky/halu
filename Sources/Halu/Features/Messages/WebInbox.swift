import Foundation

/// Unread state read straight from open browser tabs of Slack, Gmail and Telegram Web. Tabs can sit in
/// the background. Needs "Allow JavaScript from Apple Events" in the browser, same as the Media tab.
///
/// - Slack: the page's own client asks Slack for its counts (`client.counts`) and the last message of
///   each unread conversation, so it isn't limited to the part of the sidebar that's on screen.
/// - Telegram Web K: chats come from the page's own database, so any folder can be followed, open or not.
/// - Gmail: unread rows of the open list, labelled with the inbox address.
///
/// Slack and Telegram work asynchronously inside the page: each read starts a refresh there and picks
/// up the result a moment later. Nothing leaves the page but the list of unread conversations.
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
        /// Why it's here: "Mentioned you", "Direct message", "3 unread"…
        var detail: String
        /// What was said, when the site tells.
        var text = ""
        /// Which inbox, workspace or folder it came from, e.g. the Gmail address.
        var account = ""
        /// Addressed to you: a direct message or a mention.
        var isPersonal = false
        var date: Date?
        /// Where it lives, to switch to it: browser, window and tab index, and a script or page to open there.
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
        /// Sites whose tab is open but gave no answer this time: what was shown before stays.
        var pending: Set<Site> = []
        /// What each covered site is signed in as (Gmail addresses, Slack workspace, Telegram folder).
        var accounts: [Site: [String]] = [:]
        /// Telegram chat folders, in their order ("All" first).
        var telegramFolders: [String] = []
    }

    private let queue = DispatchQueue(label: "halu.web-inbox", qos: .utility)

    private static let gmailScript = """
    JSON.stringify({ account: (location.pathname.match(/\\/u\\/(\\d+)/) || [])[1] || '0',
      email: (document.title.match(/ - ([^\\s]+@[^\\s]+) - /) || [])[1] || '',
      items: [...document.querySelectorAll('tr.zA.zE')].slice(0, 30).map(r => {
        const from = r.querySelector('.yW span[email]'); const thread = r.querySelector('[data-legacy-thread-id]');
        return { id: thread ? thread.getAttribute('data-legacy-thread-id') : '',
          name: from ? (from.getAttribute('name') || from.textContent) : '',
          subject: ((r.querySelector('.bog') || {}).textContent || '').trim() }; }) })
    """

    /// Unread conversations from Slack's own API, through the page's session. Names and last messages are
    /// cached in the page and fetched again only when a conversation changes.
    private static let slackScript = """
    (() => { const S = window.__haluSlack || (window.__haluSlack = { names: {}, users: {}, last: {}, result: '', busy: false });
      if (!S.busy) { S.busy = true; (async () => {
        const cfg = JSON.parse(localStorage.getItem('localConfig_v2') || '{}');
        const teamID = location.pathname.split('/')[2];
        const team = cfg.teams && (cfg.teams[teamID] || Object.values(cfg.teams)[0]);
        if (!team) return;
        const api = async (method, params) => { const form = new FormData(); form.append('token', team.token);
          for (const k in params) form.append(k, params[k]);
          return fetch('/api/' + method, { method: 'POST', body: form, credentials: 'include' }).then(r => r.json()); };
        const user = async id => { if (!(id in S.users)) { const r = await api('users.info', { user: id });
          S.users[id] = r.ok ? (r.user.profile.display_name || r.user.real_name || r.user.name) : ''; } return S.users[id]; };
        const plain = async text => { let out = text || '';
          for (const m of out.match(/<@([A-Z0-9]+)>/g) || []) out = out.replace(m, '@' + (await user(m.slice(2, -1)) || 'someone'));
          return out.replace(/<#[A-Z0-9]+\\|([^>]+)>/g, '#$1').replace(/<!(here|channel|everyone)[^>]*>/g, '@$1')
            .replace(/<[^|>]+\\|([^>]+)>/g, '$1').replace(/<([^>]+)>/g, '$1').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&'); };
        const counts = await api('client.counts', {});
        if (!counts.ok) return;
        const list = [...(counts.ims || []).map(c => ({ ...c, kind: 'im' })), ...(counts.mpims || []).map(c => ({ ...c, kind: 'mpim' })),
          ...(counts.channels || []).map(c => ({ ...c, kind: 'channel' }))].filter(c => c.has_unreads || c.mention_count > 0).slice(0, 40);
        const items = await Promise.all(list.map(async c => {
          if (!(c.id in S.names)) { const r = await api('conversations.info', { channel: c.id });
            S.names[c.id] = !r.ok ? '' : r.channel.is_im ? await user(r.channel.user) : r.channel.is_mpim ? (r.channel.purpose && r.channel.purpose.value || r.channel.name) : '#' + r.channel.name; }
          if (!S.last[c.id] || S.last[c.id].latest !== c.latest) {
            const r = await api('conversations.history', { channel: c.id, limit: 1 });
            const m = r.ok && r.messages && r.messages[0];
            S.last[c.id] = { latest: c.latest, text: m ? await plain(m.text) : '', from: m && m.user ? await user(m.user) : (m && m.username) || '', ts: m ? m.ts : c.latest };
          }
          const last = S.last[c.id];
          return { id: c.id, kind: c.kind, name: S.names[c.id], mentions: c.mention_count || 0, text: last.text, from: last.from, ts: last.ts };
        }));
        const threads = counts.threads || {};
        S.result = JSON.stringify({ team: team.name || '', teamID: teamID || team.id || '', items,
          threads: threads.has_unreads ? (threads.mention_count || 0) + 1 : 0 });
      })().catch(() => {}).finally(() => { S.busy = false; }); }
      return S.result; })()
    """

    /// Telegram Web K keeps every dialog with its folder membership (`index_<folder local id>`) in IndexedDB.
    /// Signed-out account slots have folders but no chats and are skipped. No `//` comments in these
    /// scripts: they are sent as one line.
    private static func telegramScript(folder: String) -> String {
        let wanted = (try? String(data: JSONSerialization.data(withJSONObject: [folder.lowercased()]), encoding: .utf8)) ?? "[\"\"]"
        return """
        (() => { const want = \(wanted)[0];
          const T = window.__haluTelegram || (window.__haluTelegram = { result: {}, busy: false });
          if (!T.busy) { T.busy = true; (async () => {
            const dbs = (await indexedDB.databases()).filter(d => /^tweb-account-\\d+$/.test(d.name));
            const items = []; let folders = [], folderName = '';
            for (const info of dbs) {
              const db = await new Promise((res, rej) => { const r = indexedDB.open(info.name); r.onsuccess = () => res(r.result); r.onerror = rej; });
              const req = (store, f) => new Promise(res => { try { const q = f(db.transaction(store).objectStore(store)); q.onsuccess = () => res(q.result); q.onerror = () => res(undefined); } catch (e) { res(undefined); } });
              const filters = (await req('session', s => s.get('filtersArr'))) || [];
              const all = (await req('dialogs', s => s.getAll())) || [];
              if (!filters.length || !all.length) { db.close(); continue; }
              const clean = t => (typeof t === 'string' ? t : (t && t.text) || '').replace(/[\\p{Extended_Pictographic}\\uFE0F\\u200D]/gu, '').trim();
              folders = filters.map(f => f.id === 0 ? 'All' : clean(f.title)).filter(Boolean);
              const chosen = filters.find(f => (f.id === 0 ? 'all' : clean(f.title).toLowerCase()) === (want || 'all'));
              const index = 'index_' + (!chosen || chosen.id === 0 ? 0 : chosen.localId);
              folderName = chosen && chosen.id !== 0 ? clean(chosen.title) : 'All';
              const dialogs = all
                .filter(d => d[index] && (d.unread_count > 0 || (d.pFlags && d.pFlags.unread_mark)))
                .sort((a, b) => ((b.topMessage && b.topMessage.date) || 0) - ((a.topMessage && a.topMessage.date) || 0)).slice(0, 30);
              const name = async peerId => { if (peerId > 0) { const u = await req('users', s => s.get(String(peerId)));
                  return u ? [u.first_name, u.last_name].filter(Boolean).join(' ') : ''; }
                const c = await req('chats', s => s.get(String(-peerId))); return c ? c.title : ''; };
              for (const d of dialogs) {
                const m = d.topMessage || {};
                const from = d.peerId < 0 && m.fromId && m.fromId !== d.peerId ? await name(m.fromId) : '';
                items.push({ id: String(d.peerId), name: await name(d.peerId), badge: d.unread_count || 0,
                  mentions: d.unread_mentions_count || 0, text: m.message || (m.media ? 'Media' : ''), from, date: m.date || 0 });
              }
              db.close();
            }
            T.result[want] = JSON.stringify({ folders, folder: folderName, items });
          })().catch(() => {}).finally(() => { T.busy = false; }); }
          return T.result[want] || ''; })()
        """
    }

    func read(browsers: [String], telegramFolder: String, _ done: @escaping @MainActor (Snapshot) -> Void) {
        queue.async {
            let scripts: [Site: String] = [.slack: Self.slackScript, .gmail: Self.gmailScript,
                                           .telegram: Self.telegramScript(folder: telegramFolder)]
            // The first pass starts the in-page refreshes, the second collects them.
            for browser in browsers { _ = Self.run(browser, scripts: scripts) }
            Thread.sleep(forTimeInterval: 2.5)
            var snapshot = Snapshot(items: [], covered: [])
            for browser in browsers { Self.scan(browser, scripts: scripts, into: &snapshot) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(snapshot) } }
        }
    }

    /// Brings the item's tab to the front and opens the conversation in it.
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

    /// Runs each site's script in every matching tab. A tab that fails (asleep, still loading) gives an
    /// empty result instead of failing the whole browser. Lines: site, window, tab, result.
    private static func run(_ browser: String, scripts: [Site: String]) -> String? {
        var source = "tell application id \"\(browser)\"\nset out to \"\"\nset wi to 0\nrepeat with w in windows\nset wi to wi + 1\nset ti to 0\nrepeat with t in tabs of w\nset ti to ti + 1\nset u to URL of t\n"
        for site in Site.allCases {
            let head = "\"\(site.rawValue)\" & \"\\t\" & wi & \"\\t\" & ti & \"\\t\""
            source += "if u contains \"\(site.host)\" then\ntry\nset r to execute t javascript \"\(escape(scripts[site]!))\"\nif r is missing value then set r to \"\"\non error\nset r to \"\"\nend try\nset out to out & \(head) & r & linefeed\nend if\n"
        }
        source += "end repeat\nend repeat\nreturn out\nend tell"
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        return error == nil ? output : nil
    }

    private static func scan(_ browser: String, scripts: [Site: String], into snapshot: inout Snapshot) {
        guard let output = run(browser, scripts: scripts) else { return }
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let site = Site(rawValue: parts[0]), let window = Int(parts[1]), let tab = Int(parts[2]) else { continue }
            snapshot.covered.insert(site)
            guard parts.count == 4, let json = try? JSONSerialization.jsonObject(with: Data(parts[3].utf8)) as? [String: Any] else {
                snapshot.pending.insert(site)
                continue
            }
            let place = Place(browser: browser, window: window, tab: tab)
            switch site {
            case .slack: slack(json, at: place, into: &snapshot)
            case .gmail: gmail(json, at: place, into: &snapshot)
            case .telegram: telegram(json, at: place, into: &snapshot)
            }
        }
    }

    private struct Place { var browser: String, window: Int, tab: Int }

    private static func item(_ site: Site, key: String, title: String, detail: String, at place: Place) -> Item {
        Item(site: site, key: key, title: title, detail: detail, bundleID: place.browser, window: place.window, tab: place.tab)
    }

    private static func add(_ item: Item, to snapshot: inout Snapshot) {
        // The same conversation can show in two tabs; keep the first.
        if !snapshot.items.contains(where: { $0.key == item.key }) { snapshot.items.append(item) }
    }

    private static func note(_ account: String, for site: Site, in snapshot: inout Snapshot) {
        if !account.isEmpty, !(snapshot.accounts[site] ?? []).contains(account) { snapshot.accounts[site, default: []].append(account) }
    }

    private static func slack(_ json: [String: Any], at place: Place, into snapshot: inout Snapshot) {
        let team = json["team"] as? String ?? ""
        let teamID = json["teamID"] as? String ?? ""
        note(team, for: .slack, in: &snapshot)
        for row in json["items"] as? [[String: Any]] ?? [] {
            guard let id = row["id"] as? String else { continue }
            let kind = row["kind"] as? String ?? ""
            let mentions = row["mentions"] as? Int ?? 0
            let isDirect = kind == "im" || kind == "mpim"
            let name = row["name"] as? String ?? ""
            let from = row["from"] as? String ?? ""
            let text = row["text"] as? String ?? ""
            var entry = item(.slack, key: "Slack:\(id)", title: name.isEmpty ? "Slack" : name,
                             detail: isDirect ? "Direct message" : mentions > 0 ? "Mentioned you" : "New messages", at: place)
            entry.text = !isDirect && !from.isEmpty && !text.isEmpty ? "\(from): \(text)" : text
            entry.account = team
            entry.isPersonal = isDirect || mentions > 0
            entry.date = (row["ts"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            entry.click = "(() => { const e = document.querySelector('[data-qa-channel-sidebar-channel-id=\"\(id)\"]'); if (e) e.click(); else location.href = '/client/\(teamID)/\(id)'; })()"
            add(entry, to: &snapshot)
        }
        if let threads = json["threads"] as? Int, threads > 0 {
            var entry = item(.slack, key: "Slack:threads", title: "Threads", detail: threads > 1 ? "Mentioned you" : "New replies", at: place)
            entry.isPersonal = threads > 1
            entry.text = "New replies in threads you follow"
            entry.account = team
            entry.click = "(() => { const e = document.querySelector('[data-qa-channel-sidebar-channel-id=\"Vall_threads\"]'); if (e) e.click(); else location.href = '/client/\(teamID)/threads'; })()"
            add(entry, to: &snapshot)
        }
    }

    private static func gmail(_ json: [String: Any], at place: Place, into snapshot: inout Snapshot) {
        let email = json["email"] as? String ?? ""
        let account = json["account"] as? String ?? "0"
        note(email, for: .gmail, in: &snapshot)
        for row in json["items"] as? [[String: Any]] ?? [] {
            let id = row["id"] as? String ?? ""
            let name = row["name"] as? String ?? ""
            guard !id.isEmpty || !name.isEmpty else { continue }
            let subject = (row["subject"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(no subject)"
            var entry = item(.gmail, key: "Gmail:\(email):\(id.isEmpty ? name : id)", title: name, detail: "", at: place)
            entry.text = subject
            entry.account = email
            if !id.isEmpty { entry.url = "https://mail.google.com/mail/u/\(account)/#inbox/\(id)" }
            add(entry, to: &snapshot)
        }
    }

    private static func telegram(_ json: [String: Any], at place: Place, into snapshot: inout Snapshot) {
        if let folders = json["folders"] as? [String], !folders.isEmpty { snapshot.telegramFolders = folders }
        let folder = json["folder"] as? String ?? ""
        note(folder, for: .telegram, in: &snapshot)
        for row in json["items"] as? [[String: Any]] ?? [] {
            guard let id = row["id"] as? String else { continue }
            let badge = row["badge"] as? Int ?? 0
            let mentions = row["mentions"] as? Int ?? 0
            let from = row["from"] as? String ?? ""
            let text = row["text"] as? String ?? ""
            var entry = item(.telegram, key: "Telegram:\(id)", title: row["name"] as? String ?? "Telegram",
                             detail: mentions > 0 ? "Mentioned you" : badge > 0 ? "\(badge) unread" : "Unread", at: place)
            entry.text = from.isEmpty || text.isEmpty ? text : "\(from): \(text)"
            entry.account = folder
            entry.isPersonal = mentions > 0 || (Int(id) ?? 0) > 0
            entry.date = (row["date"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            entry.click = "(() => { location.hash = '#\(id)'; })()"
            add(entry, to: &snapshot)
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

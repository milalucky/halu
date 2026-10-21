import AppKit
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case tasks, calendar, claude, jira, messages, shelf, clipboard, translate, compare, accounts, notes, media, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .calendar: "Calendar"
        case .claude: "Claude"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .translate: "Translate"
        case .compare: "Compare"
        case .accounts: "Accounts"
        case .notes: "Notes"
        case .media: "Media"
        case .jira: "Jira"
        case .messages: "Messages"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .tasks: "checklist"
        case .calendar: "calendar"
        case .claude: "sparkle"
        case .shelf: "tray.full"
        case .clipboard: "doc.on.clipboard"
        case .translate: "character.bubble"
        case .compare: "arrow.left.arrow.right.square"
        case .accounts: "key.horizontal"
        case .notes: "note.text"
        case .media: "play.circle"
        case .jira: "ticket"
        case .messages: "bubble.left.and.bubble.right"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var tab: Tab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab") }
    }

    /// Tabs turned off in Settings; everything is on by default.
    @Published private(set) var disabledTabs: Set<Tab>

    init() {
        tab = UserDefaults.standard.string(forKey: "selectedTab").flatMap(Tab.init(rawValue:)) ?? .tasks
        disabledTabs = Set((UserDefaults.standard.stringArray(forKey: "disabledTabs") ?? []).compactMap(Tab.init(rawValue:)))
    }

    /// Tabs that can be turned off (Settings itself can't).
    static let configurable = Tab.allCases.filter { $0 != .settings }

    func isEnabled(_ tab: Tab) -> Bool { !disabledTabs.contains(tab) }

    func setEnabled(_ tab: Tab, _ enabled: Bool) {
        guard tab != .settings else { return }
        if enabled {
            disabledTabs.remove(tab)
        } else {
            // Keep at least one tab.
            guard Self.configurable.filter(isEnabled).count > 1 else { return }
            disabledTabs.insert(tab)
            if self.tab == tab { self.tab = Self.configurable.first(where: isEnabled) ?? .settings }
        }
        UserDefaults.standard.set(disabledTabs.map(\.rawValue), forKey: "disabledTabs")
    }
}

/// Owns every store; one instance shared by the panels on all displays.
@MainActor
final class Services {
    static let shared = Services()

    let model = AppModel()
    let notices = NoticeCenter()
    let tasks = TaskStore()
    let calendar = CalendarStore()
    let claude = ClaudeStore()
    let shelf = ShelfStore()
    let clipboard = ClipboardStore()
    let translate = TranslateStore()
    let accounts = AccountStore()
    let notes = NotesStore()
    let media = MediaStore()
    let jira = JiraStore()
    let messages = MessagesStore()
    let speech = SpeechInput()
    let awake = AwakeController()
    let compare = CompareStore()
    let vpn = VPNController()

    /// Something waiting for the user, shown on the collapsed notch: Claude first, then unread messages.
    var claudeWaiting: Int { model.isEnabled(.claude) ? claude.attention.count : 0 }
    var unreadMessages: Int { model.isEnabled(.messages) ? messages.unseen : 0 }
    var attentionCount: Int { claudeWaiting + unreadMessages }

    var attentionTab: Tab? {
        if claudeWaiting > 0 { return .claude }
        if unreadMessages > 0 { return .messages }
        return nil
    }

    func start() {
        let model = model
        calendar.isActive = { model.isEnabled(.calendar) }
        claude.isActive = { model.isEnabled(.claude) }
        clipboard.isActive = { model.isEnabled(.clipboard) }
        jira.isActive = { model.isEnabled(.jira) }
        media.isActive = { model.isEnabled(.media) }
        messages.isActive = { model.isEnabled(.messages) }
        shelf.isActive = { model.isEnabled(.shelf) }
        calendar.onReminder = { [notices] meeting, startsNow in
            notices.post(.meeting(meeting, startsNow: startsNow))
        }
        claude.onTransition = { [notices] session in
            switch session.status {
            case .needsInput: notices.post(.claudeNeedsInput(session))
            case .done: notices.post(.claudeFinished(session))
            default: break
            }
        }
        calendar.start()
        claude.start()
        shelf.start()
        clipboard.start()
        accounts.start()
        // `Halu --import-accounts <file>`: one-off import of a Markdown/CSV file into the vault.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--import-accounts"), flag + 1 < arguments.count {
            let added = accounts.importFile(URL(fileURLWithPath: arguments[flag + 1]))
            NSLog("Halu: imported \(added) accounts")
        }
        media.start()
        jira.start()
        messages.start()
        vpn.start()
        awake.restore()
    }
}

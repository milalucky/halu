import AppKit
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case tasks, calendar, claude, chat, jira, gitlab, messages, clipboard, translate, tools, accounts, notes, media, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .calendar: "Calendar"
        case .claude: "Claude"
        case .chat: "Chat"
        case .clipboard: "Clipboard"
        case .translate: "Translate"
        case .tools: "Tools"
        case .accounts: "Accounts"
        case .notes: "Notes"
        case .media: "Media"
        case .jira: "Jira"
        case .gitlab: "GitLab"
        case .messages: "Messages"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .tasks: "checklist"
        case .calendar: "calendar"
        case .claude: "sparkle"
        case .chat: "bubble.left.circle"
        case .clipboard: "doc.on.clipboard"
        case .translate: "character.bubble"
        case .tools: "wrench.and.screwdriver"
        case .accounts: "key.horizontal"
        case .notes: "note.text"
        case .media: "play.circle"
        case .jira: "ticket"
        case .gitlab: "arrow.triangle.branch"
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
        // Compare used to be its own tab; it lives in Tools now.
        let saved = UserDefaults.standard.string(forKey: "selectedTab")
        // Shelf is a mode of Clipboard now, and Compare of Tools.
        tab = saved == "compare" ? .tools : saved == "shelf" ? .clipboard : saved.flatMap(Tab.init(rawValue:)) ?? .tasks
        disabledTabs = Set((UserDefaults.standard.stringArray(forKey: "disabledTabs") ?? []).compactMap(Tab.init(rawValue:)))
    }

    /// Tabs that can be turned off (Settings itself can't).
    /// Chat opens from its header button, not the sidebar.
    static let configurable = Tab.allCases.filter { $0 != .settings && $0 != .chat }

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
    let chat = ChatStore()
    let tools = ToolsStore()
    let screenTools = ScreenTools()
    let gitlab = GitLabStore()
    /// Opens Halu as a normal window that stays open; set by the app delegate.
    var openWindow: () -> Void = {}
    let vpn = VPNController()
    let speed = NetworkSpeed()
    let pomodoro = PomodoroTimer()
    let claudeRequests = ClaudeRequests()
    let weather = WeatherStore()
    lazy var live = LiveCenter(calendar: calendar, pomodoro: pomodoro)

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
        shelf.isActive = { model.isEnabled(.clipboard) }
        pomodoro.onFinish = { [notices] phase in
            notices.post(phase == .focus
                ? Notice(icon: "cup.and.saucer.fill", tint: Theme.green, title: "Focus done",
                         subtitle: "Take a 5-minute break; it has started.", action: nil, actionTitle: nil,
                         tab: .tasks, duration: 12, sound: "Glass")
                : Notice(icon: "flame.fill", tint: Theme.orange, title: "Break's over",
                         subtitle: "Start another focus round from the timer.", action: nil, actionTitle: nil,
                         tab: .tasks, duration: 12, sound: "Glass"))
        }
        live.start()
        claudeRequests.start()
        weather.start()
        calendar.onReminder = { [notices] meeting, reminder in
            notices.post(.meeting(meeting, reminder))
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
        gitlab.isActive = { model.isEnabled(.gitlab) }
        gitlab.start()
        awake.restore()
    }
}

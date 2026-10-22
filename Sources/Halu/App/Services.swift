import AppKit
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case tasks, calendar, finance, claude, chat, weather, jira, gitlab, messages, clipboard, translate, tools, accounts, notes, media, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .calendar: "Calendar"
        case .claude: "Claude"
        case .chat: "Chat"
        case .finance: "Money"
        case .weather: "Weather"
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
        case .finance: "creditcard"
        case .weather: "cloud.sun"
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
        didSet {
            UserDefaults.standard.set(tab.rawValue, forKey: "selectedTab")
            Theme.accent = style.color(for: tab)
        }
    }

    /// Minimal, Playful or Neon.
    @Published var style = Style.current {
        didSet {
            UserDefaults.standard.set(style.rawValue, forKey: "style")
            Style.current = style
            Theme.accent = style.color(for: tab)
        }
    }

    enum PanelSize: String, CaseIterable, Identifiable {
        case compact = "Compact", comfortable = "Comfortable", wide = "Wide"
        var id: String { rawValue }
        var size: CGSize {
            switch self {
            case .compact: CGSize(width: 680, height: 404)
            case .comfortable: CGSize(width: 780, height: 440)
            case .wide: CGSize(width: 880, height: 480)
            }
        }
    }

    enum HoverDelay: String, CaseIterable, Identifiable {
        case quick = "Quick", normal = "Normal", relaxed = "Relaxed"
        var id: String { rawValue }
        var seconds: TimeInterval { self == .quick ? 0.04 : self == .normal ? 0.12 : 0.4 }
    }

    @Published var panelSize = PanelSize(rawValue: UserDefaults.standard.string(forKey: "panelSize") ?? "") ?? .comfortable {
        didSet {
            UserDefaults.standard.set(panelSize.rawValue, forKey: "panelSize")
            Layout.expandedWidth = panelSize.size.width
            Layout.contentHeight = panelSize.size.height
        }
    }

    /// How long the pointer rests on the notch before it opens.
    @Published var hoverDelay = HoverDelay(rawValue: UserDefaults.standard.string(forKey: "hoverDelay") ?? "") ?? .normal {
        didSet { UserDefaults.standard.set(hoverDelay.rawValue, forKey: "hoverDelay") }
    }

    /// Bumped when a file lands on the notch, for the swallow animation.
    @Published var gulps = 0

    /// Tabs turned off in Settings; everything is on by default.
    @Published private(set) var disabledTabs: Set<Tab>
    /// The sidebar's order, as arranged in Settings; tabs added in later versions go at the end.
    @Published private(set) var order: [Tab]

    init() {
        // Compare used to be its own tab; it lives in Tools now.
        let saved = UserDefaults.standard.string(forKey: "selectedTab")
        // Shelf is a mode of Clipboard now, and Compare of Tools.
        tab = saved == "compare" ? .tools : saved == "shelf" ? .clipboard : saved.flatMap(Tab.init(rawValue:)) ?? .tasks
        disabledTabs = Set((UserDefaults.standard.stringArray(forKey: "disabledTabs") ?? []).compactMap(Tab.init(rawValue:)))
        let arranged = (UserDefaults.standard.stringArray(forKey: "tabOrder") ?? []).compactMap(Tab.init(rawValue:)).filter(Self.configurable.contains)
        order = arranged + Self.configurable.filter { !arranged.contains($0) }
        Theme.accent = Style.current.color(for: tab)
        Layout.expandedWidth = panelSize.size.width
        Layout.contentHeight = panelSize.size.height
    }

    /// Tabs that can be turned off (Settings itself can't).
    /// Chat opens from its header button, not the sidebar.
    static let configurable = Tab.allCases.filter { $0 != .settings && $0 != .chat && $0 != .weather }

    func isEnabled(_ tab: Tab) -> Bool { !disabledTabs.contains(tab) }

    /// Moves a tab up (-1) or down (+1) in the sidebar.
    func move(_ tab: Tab, by step: Int) {
        guard let index = order.firstIndex(of: tab), order.indices.contains(index + step) else { return }
        order.swapAt(index, index + step)
        UserDefaults.standard.set(order.map(\.rawValue), forKey: "tabOrder")
    }

    /// Puts `tab` where `target` is (drag and drop in Settings).
    func move(_ tab: Tab, to target: Tab) {
        guard tab != target, let from = order.firstIndex(of: tab), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(tab, at: to)
        UserDefaults.standard.set(order.map(\.rawValue), forKey: "tabOrder")
    }

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
    let market = MarketStore()
    let finance = FinanceStore()
    let recordly = RecordlyBridge()
    let gitlab = GitLabStore()
    /// Opens Halu as a normal window that stays open; set by the app delegate.
    var openWindow: () -> Void = {}
    /// Folds the notch panel away (set by the app delegate).
    var collapsePanel: () -> Void = {}
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

    /// On Monday from 9:00, once: a note from the notch that last week's recap is ready.
    private func scheduleWeeklyRecap() {
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.offerRecap() }
        }
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.offerRecap() }
    }

    private func offerRecap() {
        let now = Date()
        let calendar = Calendar.current
        guard calendar.component(.weekday, from: now) == 2, calendar.component(.hour, from: now) >= 9 else { return }
        let week = WeekRecap.weekStart(now)
        guard (UserDefaults.standard.object(forKey: "recap.shown") as? Date).map({ $0 < week }) ?? true else { return }
        UserDefaults.standard.set(now, forKey: "recap.shown")
        let last = calendar.date(byAdding: .day, value: -7, to: week)!
        let recap = WeekRecap.make(for: last..<week, tasks: tasks.items)
        tasks.showingRecap = true
        notices.post(Notice(icon: "chart.bar.fill", tint: Theme.accent, title: "Your week",
                            subtitle: "\(recap.tasksDone) tasks done · \(recap.meetings) meetings · \(Int(recap.focusMinutes / 60))h in focus",
                            action: .open(.tasks), actionTitle: "See it", tab: .tasks, duration: 30, sound: "Glass"))
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
        pomodoro.onFinish = { [notices, pomodoro] phase in
            if phase == .focus { Stats.shared.log(.focus, value: pomodoro.total / 60) }
            notices.post(phase == .focus
                ? Notice(icon: "cup.and.saucer.fill", tint: Theme.green, title: "Focus done",
                         subtitle: "Take a 5-minute break; it has started.", action: nil, actionTitle: nil,
                         tab: .tasks, duration: 12, sound: "Glass")
                : Notice(icon: "flame.fill", tint: Theme.orange, title: "Break's over",
                         subtitle: "Start another focus round from the timer.", action: nil, actionTitle: nil,
                         tab: .tasks, duration: 12, sound: "Glass"))
        }
        live.start()
        scheduleWeeklyRecap()
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
        recordly.start()
        finance.rates = { [market] in market.rates }
        market.loadRates()
        gitlab.isActive = { model.isEnabled(.gitlab) }
        gitlab.onPipelineFinished = { [notices] pipeline in
            Stats.shared.log(.pipeline, key: String(pipeline.id))
            let ok = pipeline.status == .success
            notices.post(Notice(icon: ok ? "checkmark.circle.fill" : "xmark.circle.fill", tint: ok ? Theme.green : Theme.red,
                                title: ok ? "Pipeline passed" : "Pipeline \(pipeline.status.rawValue)",
                                subtitle: "\(pipeline.project) · \(pipeline.ref)", action: .open(.gitlab), actionTitle: "Open",
                                tab: .gitlab, duration: ok ? 8 : 20, sound: ok ? "Glass" : "Basso"))
        }
        gitlab.start()
        awake.restore()
    }
}

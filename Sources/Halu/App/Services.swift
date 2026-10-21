import AppKit
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case tasks, calendar, claude, jira, messages, shelf, clipboard, translate, accounts, notes, media, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .calendar: "Calendar"
        case .claude: "Claude"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .translate: "Translate"
        case .accounts: "Accounts"
        case .notes: "Notes"
        case .media: "Media"
        case .jira: "Jira"
        case .messages: "Messages"
        case .settings: "Integrations"
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

    init() {
        tab = UserDefaults.standard.string(forKey: "selectedTab").flatMap(Tab.init(rawValue:)) ?? .tasks
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

    func start() {
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
        media.start()
        jira.start()
        messages.start()
    }
}

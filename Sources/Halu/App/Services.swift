import AppKit
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case tasks, calendar, claude, shelf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .calendar: "Calendar"
        case .claude: "Claude"
        case .shelf: "Shelf"
        }
    }

    var icon: String {
        switch self {
        case .tasks: "checklist"
        case .calendar: "calendar"
        case .claude: "sparkle"
        case .shelf: "tray.full"
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
    }
}

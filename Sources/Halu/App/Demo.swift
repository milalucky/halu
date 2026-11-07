import AppKit
import HaluCore
import SwiftUI

/// `Halu --demo`: made-up data for screenshots. Data lives in Application Support/Halu-Demo, the
/// Keychain is never touched, and nothing outside the Mac is read (calendars, Claude sessions,
/// messages, mail, GitLab, Jira, the clipboard and screenshots stay off). Run it from a copy with its
/// own bundle identifier (scripts/screenshots.sh) so settings stay apart too.
enum Demo {
    static let isOn = CommandLine.arguments.contains("--demo")
    private static var backdrop: NSWindow?

    /// Covers the main screen with its desktop picture, under the notch panel, so screenshots show
    /// only the wallpaper behind the glass and never your other windows.
    @MainActor
    static func showBackdrop() {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url) else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        let view = NSImageView(image: image)
        view.imageScaling = .scaleAxesIndependently
        window.contentView = view
        window.level = .floating
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        backdrop = window
    }

    @MainActor
    static func seed(_ services: Services) {
        let now = Date()
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

        services.calendar.loadDemo([
            Meeting(id: "lunch", title: "Lunch", start: at(-200), end: at(-140), isAllDay: false,
                    color: Theme.orange, calendarName: "Personal", joinURL: nil),
            Meeting(id: "review", title: "Design review", start: at(8), end: at(38), isAllDay: false,
                    color: Theme.red, calendarName: "Work", joinURL: URL(string: "https://meet.google.com/")),
            Meeting(id: "planning", title: "Sprint planning", start: at(80), end: at(140), isAllDay: false,
                    color: Theme.blue, calendarName: "Work", joinURL: URL(string: "https://meet.google.com/")),
            Meeting(id: "one-on-one", title: "1:1 with Alex", start: at(170), end: at(200), isAllDay: false,
                    color: Theme.accent, calendarName: "Work", joinURL: URL(string: "https://zoom.us/")),
            Meeting(id: "sync", title: "Product sync", start: at(24 * 60 + 30), end: at(24 * 60 + 60), isAllDay: false,
                    color: Theme.blue, calendarName: "Work", joinURL: URL(string: "https://meet.google.com/")),
        ])

        func session(_ id: String, _ project: String, _ title: String, _ status: ClaudeStatus, done: Int, of total: Int,
                     minutesAgo: Double, message: String? = nil) -> ClaudeSession {
            var session = ClaudeSession(id: id, cwd: "/Users/demo/Projects/\(project)", now: at(-minutesAgo - 30))
            session.title = title
            session.status = status
            session.message = message
            session.updatedAt = at(-minutesAgo)
            session.turnStartedAt = at(-minutesAgo - 4)
            session.steps = (0..<total).map { index in
                ClaudeStep(content: ["Read the code", "Plan the change", "Write it", "Add tests", "Run the build"][index % 5],
                           status: index < done ? "completed" : index == done ? "in_progress" : "pending")
            }
            return session
        }
        services.claude.loadDemo([
            ClaudeRow(session: session("a", "api", "Fix the flaky auth tests", .needsInput, done: 2, of: 4, minutesAgo: 1,
                                       message: "Claude needs your permission to use Bash"), phase: .needsYou),
            ClaudeRow(session: session("b", "halu", "Add a weekly recap chart", .working, done: 3, of: 5, minutesAgo: 0), phase: .working),
            ClaudeRow(session: session("c", "site", "Polish the landing page copy", .idle, done: 4, of: 4, minutesAgo: 12), phase: .yourTurn),
        ])

        services.messages.loadDemo([
            IncomingMessage(id: 1, appID: "com.tinyspeck.slackmacgap", appName: "Slack", title: "Alex Kim", subtitle: "#design",
                            body: "Love the new glow on the notch", date: at(-3), isPersonal: true),
            IncomingMessage(id: 2, appID: "ru.keepcoder.Telegram", appName: "Telegram", title: "Mia", subtitle: "",
                            body: "Still on for Friday?", date: at(-9), isPersonal: true),
            IncomingMessage(id: 3, appID: "com.google.Gmail", appName: "Gmail", title: "Weekly report", subtitle: "",
                            body: "Your team shipped 14 changes this week", date: at(-25)),
            IncomingMessage(id: 4, appID: "com.tinyspeck.slackmacgap", appName: "Slack", title: "#releases", subtitle: "",
                            body: "v2.4 is out", date: at(-40)),
        ])

        services.media.loadDemo(MediaSource(pid: ProcessInfo.processInfo.processIdentifier, appName: "Music", bundleID: "com.apple.Music",
                                            title: "Weightless — Marconi Union", isPlaying: true, lastHeard: now))

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        services.weather.loadDemo(
            place: "Lisbon",
            now: .init(temperature: 19, feelsLike: 18, code: 1, isDay: true, high: 21, low: 14, wind: 12),
            hours: (0..<24).map { step in
                let time = calendar.date(bySettingHour: (hour + step) % 24, minute: 0, second: 0, of: now) ?? now
                return .init(time: time.addingTimeInterval(hour + step >= 24 ? 86400 : 0), temperature: 19 - abs(Double(step) - 3) * 0.6,
                             code: step < 6 ? 1 : step < 12 ? 3 : 0, isDay: (hour + step) % 24 >= 7 && (hour + step) % 24 < 19,
                             rainChance: step < 6 ? 10 : 30)
            },
            days: (0..<7).map { day in
                .init(date: calendar.date(byAdding: .day, value: day, to: now) ?? now, code: [1, 3, 61, 2, 0, 0, 1][day],
                      high: [21, 19, 17, 20, 23, 24, 22][day], low: [14, 13, 12, 13, 15, 16, 15][day], rainChance: [10, 30, 80, 20, 0, 0, 10][day])
            })

        for title in ["Review the onboarding flow #work", "Send sprint notes #work", "Book a dentist appointment #home",
                      "Try Halu on the external display #halu", "Groceries: oat milk, lemons, rice #home", "Update the README #halu",
                      "Plan the team offsite #work"] {
            services.tasks.add(title)
        }
        for item in services.tasks.items.suffix(2) { services.tasks.complete(item.id) }

        let habits = services.habits
        if let water = habits.habits.first(where: { $0.name == "Water" }) { habits.bump(water, by: 5) }
        if let workout = habits.habits.first(where: { $0.name == "Workout" }) { habits.bump(workout, by: 1) }
        var reading = Habit(name: "Read", emoji: "📖", goal: 20, unit: "pages")
        for day in 1...9 { reading.log[HabitStore.key(at(Double(-day) * 1440))] = 20 }
        reading.log[HabitStore.key(now)] = 12
        habits.save(reading)

        let finance = services.finance
        for line in ["180000 salary", "350 coffee", "1200 taxi", "4800 groceries", "890 lunch", "2500 cinema", "15000 rent", "640 coffee", "3100 groceries"] {
            finance.draft = line
            finance.addDraft()
        }

        for (name, url) in [("Staging", "https://staging.example.com"), ("QA", "https://qa.example.com"), ("Preview", "https://preview.example.com")] {
            services.stands.save(Stand(name: name, url: url))
        }

        services.pomodoro.startFocus()
    }
}

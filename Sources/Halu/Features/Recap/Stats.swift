import EventKit
import Foundation

/// A small local diary of what happened, for the weekly recap: focus rounds, Claude sessions,
/// meetings joined, pipelines. Kept 90 days in UserDefaults; nothing leaves the Mac.
@MainActor
final class Stats {
    static let shared = Stats()

    enum Kind: String, Codable { case focus, claudeSession, meetingJoined, pipeline }

    struct Entry: Codable {
        var kind: Kind
        var date: Date
        /// Minutes for focus; 1 otherwise.
        var value: Double
        var key: String?
    }

    private(set) var entries: [Entry]

    private init() {
        entries = (UserDefaults.standard.data(forKey: "stats.log")).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// Records once per `key` (a session or pipeline id), or every time without one.
    func log(_ kind: Kind, value: Double = 1, date: Date = .now, key: String? = nil) {
        if let key, entries.contains(where: { $0.kind == kind && $0.key == key }) { return }
        entries.append(Entry(kind: kind, date: date, value: value, key: key))
        entries.removeAll { Date().timeIntervalSince($0.date) > 90 * 86400 }
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: "stats.log") }
    }

    func total(_ kind: Kind, in range: Range<Date>) -> Double {
        entries.filter { $0.kind == kind && range.contains($0.date) }.reduce(0) { $0 + $1.value }
    }
}

/// One week in numbers.
struct WeekRecap {
    var range: Range<Date>
    var tasksDone: Int
    var tasksPerDay: [Int]
    var topTags: [(String, Int)]
    var focusMinutes: Double
    var meetings: Int
    var meetingHours: Double
    var claudeSessions: Int
    var pipelines: Int

    /// Monday 00:00 of the week `date` is in.
    static func weekStart(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? Calendar.current.startOfDay(for: date)
    }

    @MainActor
    static func make(for range: Range<Date>, tasks: [TaskItem]) -> WeekRecap {
        let done = tasks.filter { $0.doneAt.map(range.contains) ?? false }
        let calendar = Calendar.current
        var perDay = Array(repeating: 0, count: 7)
        for task in done {
            let day = calendar.dateComponents([.day], from: range.lowerBound, to: task.doneAt!).day ?? 0
            if perDay.indices.contains(day) { perDay[day] += 1 }
        }
        var tags: [String: Int] = [:]
        done.flatMap(\.tags).forEach { tags[$0, default: 0] += 1 }

        // Meetings from the calendar: timed events you were in.
        let store = EKEventStore()
        var meetings = 0
        var hours = 0.0
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let events = store.events(matching: store.predicateForEvents(withStart: range.lowerBound, end: min(range.upperBound, Date()), calendars: nil))
            for event in events where !event.isAllDay && event.status != .canceled && event.endDate.timeIntervalSince(event.startDate) < 6 * 3600
                && !Meeting.isLunch(event.title ?? "") {
                meetings += 1
                hours += event.endDate.timeIntervalSince(event.startDate) / 3600
            }
        }
        let stats = Stats.shared
        return WeekRecap(range: range, tasksDone: done.count, tasksPerDay: perDay,
                         topTags: tags.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value) },
                         focusMinutes: stats.total(.focus, in: range), meetings: meetings, meetingHours: hours,
                         claudeSessions: Int(stats.total(.claudeSession, in: range)), pipelines: Int(stats.total(.pipeline, in: range)))
    }
}

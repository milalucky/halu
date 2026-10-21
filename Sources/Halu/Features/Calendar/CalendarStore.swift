import AppKit
import EventKit
import SwiftUI

struct Meeting: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
    let calendarName: String
    let joinURL: URL?

    func isLive(at now: Date) -> Bool { start <= now && end > now }
}

/// Reads events through EventKit, so a Google account added in System Settings → Internet Accounts
/// shows up here without any extra sign-in.
@MainActor
final class CalendarStore: ObservableObject {
    /// False while the tab is turned off in Settings: background work pauses.
    var isActive: () -> Bool = { true }

    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var meetings: [Meeting] = []

    enum Reminder { case soon, oneMinute, started, stillGoing }

    /// Called for each reminder: 5 min before, 1 min before, at the start, and 2 min in if you haven't joined.
    var onReminder: (Meeting, Reminder) -> Void = { _, _ in }
    /// How long before a meeting the notch starts counting down.
    let countdownLead: TimeInterval = 15 * 60
    /// Meetings you joined from Halu: no more reminders or countdown for them.
    @Published private(set) var joined: Set<String> = []
    /// Meetings whose countdown you closed.
    @Published private(set) var dismissed: Set<String> = []

    private let store = EKEventStore()
    private var notified: Set<String> = []
    private var timer: Timer?

    func start() {
        refreshAccess()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Int(Date().timeIntervalSince1970) % 300 < 5 { self.reload() }
                self.checkReminders()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func requestAccess() {
        store.requestFullAccessToEvents { @Sendable [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshAccess() }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func openInternetAccounts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .granted
            reload()
        case .notDetermined:
            access = .unknown
        default:
            access = .denied
        }
    }

    func reload() {
        guard access == .granted else { return }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        guard let end = calendar.date(byAdding: .day, value: 2, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        meetings = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map { event in
                Meeting(
                    id: "\(event.eventIdentifier ?? event.title ?? "")-\(event.startDate.timeIntervalSince1970)",
                    title: event.title?.isEmpty == false ? event.title! : "Untitled",
                    start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                    color: Color(cgColor: event.calendar.cgColor),
                    calendarName: event.calendar.title,
                    joinURL: Self.joinURL(for: event)
                )
            }
            .sorted { $0.start < $1.start }
        checkReminders()
    }

    /// The meeting the notch counts down to: starting within 15 minutes, or started up to 10 minutes ago
    /// and not joined. Video calls first.
    func countdown(at now: Date = .now) -> Meeting? {
        meetings.filter { meeting in
            guard !meeting.isAllDay, !joined.contains(meeting.id), !dismissed.contains(meeting.id) else { return false }
            let lead = meeting.start.timeIntervalSince(now)
            return lead <= countdownLead && lead > -10 * 60
        }
        .min { a, b in
            if (a.joinURL != nil) != (b.joinURL != nil) { return a.joinURL != nil }
            return a.start < b.start
        }
    }

    /// Opens the call and stops the reminders for it.
    func join(_ meeting: Meeting) {
        joined.insert(meeting.id)
        Stats.shared.log(.meetingJoined, key: meeting.id)
        if let url = meeting.joinURL { NSWorkspace.shared.open(url) }
    }

    func markJoined(url: URL) {
        for meeting in meetings where meeting.joinURL == url { joined.insert(meeting.id) }
    }

    func dismissCountdown(_ meeting: Meeting) {
        dismissed.insert(meeting.id)
    }

    func checkReminders() {
        guard isActive() else { return }
        let now = Date()
        for meeting in meetings where !meeting.isAllDay && !joined.contains(meeting.id) {
            let lead = meeting.start.timeIntervalSince(now)
            let steps: [(Reminder, Bool)] = [
                (.soon, lead <= 5 * 60 && lead > 90),
                (.oneMinute, lead <= 75 && lead > 5),
                (.started, lead <= 5 && lead > -90),
                (.stillGoing, lead <= -120 && lead > -10 * 60),
            ]
            // Only the latest due step fires; earlier ones it skipped over are marked done.
            guard let due = steps.lastIndex(where: { $0.1 }) else { continue }
            let key = "\(meeting.id)#\(due)"
            guard notified.insert(key).inserted else { continue }
            (0..<due).forEach { notified.insert("\(meeting.id)#\($0)") }
            onReminder(meeting, steps[due].0)
        }
    }

    private static let callHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com"]
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// First video-call link found in the event's URL, location or notes.
    static func joinURL(for event: EKEvent) -> URL? {
        let texts = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector?.matches(in: text, range: range) ?? [] {
                guard let url = match.url, let host = url.host?.lowercased() else { continue }
                if callHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) { return url }
            }
        }
        return nil
    }
}

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

    /// Called with the meeting and whether it is starting right now (otherwise it is the early reminder).
    var onReminder: (Meeting, Bool) -> Void = { _, _ in }
    let reminderLead: TimeInterval = 10 * 60

    private let store = EKEventStore()
    private var notified: Set<String> = []
    private var timer: Timer?

    func start() {
        refreshAccess()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Int(Date().timeIntervalSince1970) % 300 < 20 { self.reload() }
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

    private func checkReminders() {
        guard isActive() else { return }
        let now = Date()
        for meeting in meetings where !meeting.isAllDay {
            let lead = meeting.start.timeIntervalSince(now)
            if lead > 60, lead <= reminderLead, notified.insert("\(meeting.id)#early").inserted {
                onReminder(meeting, false)
            } else if lead <= 60, lead > -120, notified.insert("\(meeting.id)#now").inserted {
                notified.insert("\(meeting.id)#early")
                onReminder(meeting, true)
            }
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

import AppKit
import HaluCore
import SwiftUI

/// A message that drops out of the notch on its own: a meeting reminder or a Claude session update.
struct Notice: Identifiable, Equatable {
    enum Action: Equatable {
        case join(URL)
        case open(Tab)
    }

    let id = UUID()
    var icon: String
    var tint: Color
    var title: String
    var subtitle: String
    var action: Action?
    var actionTitle: String?
    var tab: Tab
    var duration: TimeInterval
    var sound: String?

    static func meeting(_ meeting: Meeting, _ reminder: CalendarStore.Reminder) -> Notice {
        let when: String
        let tint: Color
        switch reminder {
        case .soon: (when, tint) = ("Starts \(Fmt.until(meeting.start))", Theme.accent)
        case .oneMinute: (when, tint) = ("Starts in a minute", Theme.orange)
        case .started: (when, tint) = ("Starting now", Theme.green)
        case .stillGoing: (when, tint) = ("Already going for \(Int(-meeting.start.timeIntervalSinceNow / 60)) min", Theme.red)
        }
        return Notice(
            icon: reminder == .stillGoing ? "exclamationmark.circle.fill" : "video.fill", tint: tint,
            title: meeting.title,
            subtitle: "\(when) · \(Fmt.time.string(from: meeting.start))–\(Fmt.time.string(from: meeting.end))",
            action: meeting.joinURL.map { .join($0) } ?? .open(.calendar),
            actionTitle: meeting.joinURL == nil ? "Open" : "Join",
            tab: .calendar, duration: reminder == .soon ? 30 : 120,
            sound: reminder == .soon ? "Glass" : reminder == .oneMinute ? "Ping" : "Hero"
        )
    }

    static func claudeNeedsInput(_ session: ClaudeSession) -> Notice {
        Notice(
            icon: "hand.raised.fill", tint: Theme.orange,
            title: "Claude needs you",
            subtitle: "\(session.project) · \(session.message ?? session.displayTitle)",
            action: .open(.claude), actionTitle: "Open",
            tab: .claude, duration: 14, sound: "Tink"
        )
    }

    static func claudeFinished(_ session: ClaudeSession) -> Notice {
        Notice(
            icon: "arrow.turn.down.left", tint: Theme.blue,
            title: "Your turn",
            subtitle: "\(session.project) · \(session.displayTitle)",
            action: .open(.claude), actionTitle: "Open",
            tab: .claude, duration: 8, sound: nil
        )
    }
}

@MainActor
final class NoticeCenter: ObservableObject {
    @Published private(set) var current: Notice?
    /// Set by the controller while the pointer rests on the notice; pauses the auto-dismiss.
    var isHovered = false

    private var queue: [Notice] = []
    private var dismissWork: DispatchWorkItem?

    func post(_ notice: Notice) {
        if current == nil {
            show(notice)
        } else {
            queue.append(notice)
        }
    }

    /// Drops Claude notices: a request card in the notch is asking the same thing.
    func dismissClaude() {
        queue.removeAll { $0.tab == .claude }
        if current?.tab == .claude { dismiss() }
    }

    func dismiss() {
        dismissWork?.cancel()
        current = nil
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.show(next) }
    }

    private func show(_ notice: Notice) {
        current = notice
        if let sound = notice.sound { NSSound(named: NSSound.Name(sound))?.play() }
        scheduleDismiss(after: notice.duration, id: notice.id)
    }

    private func scheduleDismiss(after delay: TimeInterval, id: UUID) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.current?.id == id else { return }
            if self.isHovered {
                self.scheduleDismiss(after: 2, id: id)
            } else {
                self.dismiss()
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

struct NoticeView: View {
    let notice: Notice
    let top: CGFloat
    let notices: NoticeCenter
    let actions: PanelActions
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: top)
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(notice.tint.opacity(0.16))
                    Image(systemName: notice.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(notice.tint)
                        .symbolEffect(.bounce, value: appeared)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    Text(notice.subtitle)
                        .font(Theme.caption(11.5, weight: .regular))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)

                if let action = notice.action, let title = notice.actionTitle {
                    PillButton(title: title, icon: title == "Join" ? "video.fill" : nil, tint: notice.tint) {
                        perform(action)
                    }
                }
                IconButton(icon: "xmark", help: "Dismiss", size: 9) { notices.dismiss() }
            }
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .offset(y: appeared ? 0 : -14)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.05)) { appeared = true } }
        .onTapGesture {
            notices.dismiss()
            actions.open(notice.tab)
        }
    }

    private func perform(_ action: Notice.Action) {
        notices.dismiss()
        switch action {
        case .join(let url):
            Services.shared.calendar.markJoined(url: url)
            NSWorkspace.shared.open(url)
        case .open(let tab): actions.open(tab)
        }
    }
}

import AppKit
import SwiftUI

struct CalendarView: View {
    @ObservedObject var store: CalendarStore

    var body: some View {
        switch store.access {
        case .granted:
            TimelineView(.periodic(from: .now, by: 30)) { context in
                agenda(now: context.date)
            }
        case .unknown:
            EmptyState(icon: "calendar.badge.plus", title: "Connect your calendar",
                       subtitle: "Halu reads the calendars on this Mac. Add your Google account in Internet Accounts, then allow access.",
                       action: ("Allow access", store.requestAccess))
        case .denied:
            EmptyState(icon: "calendar.badge.exclamationmark", title: "Calendar access is off",
                       subtitle: "Turn on Halu in Privacy & Security → Calendars.",
                       action: ("Open Settings", store.openPrivacySettings))
        }
    }

    private func agenda(now: Date) -> some View {
        let calendar = Calendar.current
        let today = store.meetings.filter { calendar.isDateInToday($0.start) || $0.isLive(at: now) }
        let tomorrow = store.meetings.filter { calendar.isDateInTomorrow($0.start) }
        let next = today.first { !$0.isAllDay && $0.end > now }

        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Today", detail: summary(today, now: now), trailing: AnyView(
                IconButton(icon: "person.crop.circle.badge.plus", help: "Add a Google account", action: store.openInternetAccounts)
            ))

            if store.meetings.isEmpty {
                EmptyState(icon: "sun.max", title: "No meetings",
                           subtitle: "Nothing on your calendars today or tomorrow.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if today.isEmpty {
                            Text("Free day").font(Theme.body()).foregroundStyle(Theme.tertiary).padding(10)
                        }
                        ForEach(today) { meeting in
                            MeetingRow(meeting: meeting, now: now, highlighted: meeting.id == next?.id)
                        }
                        if !tomorrow.isEmpty {
                            Text("TOMORROW")
                                .font(Theme.caption(10, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(Theme.tertiary)
                                .padding(.top, 12)
                                .padding(.leading, 10)
                            ForEach(tomorrow) { meeting in
                                MeetingRow(meeting: meeting, now: now, highlighted: false)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func summary(_ meetings: [Meeting], now: Date) -> String? {
        let left = meetings.filter { !$0.isAllDay && $0.end > now }.count
        return left == 0 ? nil : (left == 1 ? "1 meeting left" : "\(left) meetings left")
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let now: Date
    let highlighted: Bool

    private var isPast: Bool { meeting.end <= now }
    private var isLive: Bool { meeting.isLive(at: now) }

    var body: some View {
        HoverRow(padding: EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 8)) { _ in
            HStack(spacing: 12) {
                VStack(alignment: .trailing, spacing: 1) {
                    if meeting.isAllDay {
                        Text("all day").font(Theme.caption(11, weight: .semibold))
                    } else {
                        Text(Fmt.time.string(from: meeting.start)).font(Theme.caption(12, weight: .semibold))
                        Text(Fmt.time.string(from: meeting.end)).font(Theme.caption(10.5, weight: .regular)).foregroundStyle(Theme.tertiary)
                    }
                }
                .monospacedDigit()
                .foregroundStyle(isPast ? Theme.tertiary : Theme.primary)
                .frame(width: 42, alignment: .trailing)

                Capsule().fill(meeting.color.opacity(isPast ? 0.35 : 1)).frame(width: 3, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(Theme.body(13, weight: highlighted ? .semibold : .regular))
                        .foregroundStyle(isPast ? Theme.tertiary : Theme.primary)
                        .lineLimit(1)
                    Text(meeting.calendarName)
                        .font(Theme.caption(11, weight: .regular))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)

                if !isPast && !meeting.isAllDay {
                    Text(isLive ? "now" : Fmt.until(meeting.start, now: now))
                        .font(Theme.caption(11, weight: .semibold))
                        .foregroundStyle(isLive ? Theme.green : (highlighted ? Theme.accent : Theme.tertiary))
                }
                if let url = meeting.joinURL, !isPast {
                    PillButton(title: "Join", icon: "video.fill", tint: isLive ? Theme.green : Theme.accent,
                               prominent: isLive || highlighted) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(highlighted ? Theme.accent.opacity(0.08) : .clear)
        )
    }
}

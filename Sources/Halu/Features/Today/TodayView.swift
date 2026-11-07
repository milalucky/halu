import SwiftUI

/// Home tab: one look at the day. Each tile is a window onto another tab's store and opens that tab;
/// tiles of tabs turned off in Settings are left out.
struct TodayView: View {
    @ObservedObject var model: AppModel
    let services: Services

    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 10
            let unit = (proxy.size.width - 2 * gap) / 4
            HStack(alignment: .top, spacing: gap) {
                column(width: unit * 2) {
                    if model.isEnabled(.calendar) { MeetingTile(store: services.calendar) { open(.calendar) } }
                    if model.isEnabled(.media) { MediaTile(store: services.media) { open(.media) } }
                    FocusTile(pomodoro: services.pomodoro)
                }
                column(width: unit) {
                    if model.isEnabled(.claude) { ClaudeTile(store: services.claude) { open(.claude) } }
                    if model.isEnabled(.messages) { MessagesTile(store: services.messages) { open(.messages) } }
                }
                column(width: unit) {
                    if model.isEnabled(.tasks) { TasksTile(store: services.tasks) { open(.tasks) } }
                    if model.isEnabled(.habits) { HabitsTile(store: services.habits) { open(.habits) } }
                }
            }
        }
        .padding(.top, 2)
    }

    private func column<Content: View>(width: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10, content: content).frame(width: width).frame(maxHeight: .infinity, alignment: .top)
    }

    private func open(_ tab: Tab) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.tab = tab }
    }
}

// MARK: - Tile chrome

/// A rounded tile tinted with its tab's colour, with a label that opens the tab.
private struct Tile<Content: View>: View {
    let tab: Tab
    var label: String?
    let open: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        let tint = Style.current.color(for: tab)
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) {
                HStack(spacing: 6) {
                    Group {
                        if tab == .claude {
                            ClaudeMark().stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round)).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: tab.icon).font(.system(size: 11, weight: .semibold))
                        }
                    }
                    Text(label ?? tab.title).font(Theme.caption(11.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).opacity(hovering ? 0.8 : 0)
                }
                .foregroundStyle(tint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(tab.title)")
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(tint.opacity(hovering ? 0.15 : 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tint.opacity(0.2), lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct BigNumber: View {
    let value: String
    var unit: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.system(size: 26, weight: .heavy, design: .rounded)).monospacedDigit()
                .foregroundStyle(Theme.primary)
            if let unit { Text(unit).font(Theme.caption(12, weight: .semibold)).foregroundStyle(Theme.secondary) }
        }
    }
}

private struct Bar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(tint).frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Tiles

private struct MeetingTile: View {
    @ObservedObject var store: CalendarStore
    let open: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let next = store.meetings.first { !$0.isAllDay && $0.end > now && Calendar.current.isDate($0.start, inSameDayAs: now) }
            Tile(tab: .calendar, label: next.map { $0.isLive(at: now) ? "Now" : "Next" } ?? "Calendar", open: open) {
                if let next {
                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(next.title).font(.system(size: 19, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.primary).lineLimit(1)
                            Text("\(Fmt.time.string(from: next.start)) · \(next.isLive(at: now) ? "going on" : Fmt.until(next.start, now: now))")
                                .font(Theme.caption(12)).foregroundStyle(Theme.secondary)
                        }
                        Spacer(minLength: 0)
                        if next.joinURL != nil {
                            PillButton(title: store.joined.contains(next.id) ? "Rejoin" : "Join", icon: "video.fill",
                                       tint: Style.current.color(for: .calendar)) { store.join(next) }
                        }
                    }
                } else {
                    Text(store.access == .granted ? "No more meetings today" : "Calendar access is off")
                        .font(Theme.body(13)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .frame(height: 96)
    }
}

private struct MediaTile: View {
    @ObservedObject var store: MediaStore
    let open: () -> Void

    var body: some View {
        Tile(tab: .media, label: store.source?.isPlaying == true ? "Now playing" : "Media", open: open) {
            if let source = store.source {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.browser?.title ?? source.title ?? source.appName)
                            .font(Theme.body(13, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                        Text(source.appName).font(Theme.caption(11.5)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button {
                        if store.isBrowserSource { store.browserCommand(.toggle) } else { store.send(.playPause) }
                    } label: {
                        Image(systemName: source.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.85))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Style.current.color(for: .media)))
                    }
                    .buttonStyle(.plain)
                    .help(source.isPlaying ? "Pause" : "Play")
                }
            } else {
                Text("Nothing playing").font(Theme.body(13)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(height: 84)
    }
}

private struct FocusTile: View {
    @ObservedObject var pomodoro: PomodoroTimer

    var body: some View {
        let tint = Style.current.color(for: .habits)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = Int(pomodoro.left(at: context.date))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "timer").font(.system(size: 11, weight: .semibold))
                    Text(pomodoro.isOn ? (pomodoro.phase == .focus ? "Focus" : "Break") : "Focus")
                        .font(Theme.caption(11.5, weight: .semibold))
                }
                .foregroundStyle(tint)
                HStack(alignment: .center) {
                    BigNumber(value: pomodoro.isOn ? String(format: "%d:%02d", left / 60, left % 60) : "\(pomodoro.focusMinutes):00")
                    Spacer(minLength: 0)
                    PillButton(title: pomodoro.isRunning ? "Pause" : pomodoro.isOn ? "Resume" : "Start", tint: tint, action: pomodoro.toggle)
                    if pomodoro.isOn {
                        PillButton(title: "Stop", tint: tint, prominent: false, action: pomodoro.stop)
                    }
                }
                if pomodoro.isOn { Bar(value: 1 - pomodoro.remaining(at: context.date), tint: tint) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(tint.opacity(0.11)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tint.opacity(0.2), lineWidth: 1))
        }
    }
}

private struct ClaudeTile: View {
    @ObservedObject var store: ClaudeStore
    let open: () -> Void

    var body: some View {
        let tint = Style.current.color(for: .claude)
        let live = store.rows.filter { $0.phase <= .yourTurn }
        let working = live.filter { $0.phase == .working }.count
        Tile(tab: .claude, open: open) {
            BigNumber(value: "\(working)", unit: "working")
            VStack(alignment: .leading, spacing: 7) {
                ForEach(live.prefix(3)) { row in
                    HStack(spacing: 6) {
                        Circle().fill(row.phase == .needsYou ? Theme.orange : row.phase == .working ? tint : Theme.tertiary)
                            .frame(width: 6, height: 6)
                        Text(row.session.displayTitle).font(Theme.caption(12, weight: .regular))
                            .foregroundStyle(Theme.primary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            if !store.attention.isEmpty {
                Text("\(store.attention.count) waiting for you")
                    .font(Theme.caption(11.5, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.orange.opacity(0.14)))
            }
        }
    }
}

private struct TasksTile: View {
    @ObservedObject var store: TaskStore
    let open: () -> Void

    var body: some View {
        let tint = Style.current.color(for: .tasks)
        Tile(tab: .tasks, open: open) {
            BigNumber(value: "\(store.open.count)", unit: "left")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(store.open.prefix(5)) { task in
                    HStack(spacing: 7) {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { store.complete(task.id) }
                        } label: {
                            Circle().strokeBorder(tint.opacity(0.8), lineWidth: 1.5).frame(width: 13, height: 13)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Done")
                        Text(task.title).font(Theme.caption(12, weight: .regular)).foregroundStyle(Theme.primary).lineLimit(1)
                    }
                }
            }
        }
    }
}

private struct MessagesTile: View {
    @ObservedObject var store: MessagesStore
    let open: () -> Void

    var body: some View {
        Tile(tab: .messages, label: store.messages.isEmpty ? "Messages" : "Messages · \(store.messages.count)", open: open) {
            if store.messages.isEmpty {
                Text("All read").font(Theme.caption(12, weight: .regular)).foregroundStyle(Theme.secondary)
            }
            ForEach(store.messages.prefix(2)) { message in
                Button { store.open(message) } label: {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 1.5).fill(SourceColor.of(message.appName)).frame(width: 3, height: 14)
                        Text(message.title.isEmpty ? message.body : "\(message.title): \(message.body)")
                            .font(Theme.caption(12, weight: .regular)).foregroundStyle(Theme.primary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 100)
    }
}

private struct HabitsTile: View {
    @ObservedObject var store: HabitStore
    let open: () -> Void

    var body: some View {
        Tile(tab: .habits, open: open) {
            HStack(spacing: 10) {
                ForEach(store.habits.prefix(3)) { habit in
                    let count = store.count(habit)
                    Button { store.bump(habit, by: 1) } label: {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.1), lineWidth: 4)
                            Circle().trim(from: 0, to: min(1, Double(count) / Double(max(1, habit.goal))))
                                .stroke(Style.current.color(for: .habits), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text(habit.emoji).font(.system(size: 13))
                        }
                        .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .help("\(habit.name): \(count)/\(habit.goal) · click to add one")
                }
            }
        }
        .frame(height: 100)
    }
}

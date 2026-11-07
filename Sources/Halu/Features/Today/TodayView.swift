import AppKit
import SwiftUI

/// The tiles Today can show.
enum TodayTile: String, CaseIterable, Codable, Identifiable {
    case meeting, claude, tasks, focus, messages, habits, media
    case weather, system, gitlab, jira, clipboard, notes, money, stands, shortcuts, translate
    var id: String { rawValue }

    /// The tab the tile comes from; it is left out while that tab is off in Settings.
    var tab: Tab? {
        switch self {
        case .meeting: .calendar
        case .claude: .claude
        case .tasks: .tasks
        case .messages: .messages
        case .habits: .habits
        case .media: .media
        case .focus: nil
        case .weather: .weather
        case .system: .system
        case .gitlab: .gitlab
        case .jira: .jira
        case .clipboard: .clipboard
        case .notes: .notes
        case .money: .finance
        case .stands: .environments
        case .shortcuts: .shortcuts
        case .translate: .translate
        }
    }

    var title: String {
        switch self {
        case .meeting: "Next meeting"
        case .focus: "Focus timer"
        default: tab?.title ?? rawValue
        }
    }

    var icon: String { self == .focus ? "timer" : tab?.icon ?? "square" }
}

/// Which tiles Today shows, in what order and how wide; kept in UserDefaults ("today.layout").
@MainActor
final class TodayLayout: ObservableObject {
    enum Size: String, Codable, CaseIterable {
        case small, medium, large
        /// Share of a row, out of four.
        var units: Int { self == .small ? 1 : self == .medium ? 2 : 4 }
        var title: String { rawValue.capitalized }
    }

    struct Slot: Codable, Equatable, Identifiable {
        var tile: TodayTile
        var size: Size
        var shown = true
        var id: TodayTile { tile }

        init(tile: TodayTile, size: Size, shown: Bool = true) {
            self.tile = tile
            self.size = size
            self.shown = shown
        }

        // Layouts saved before sizes had a Small/Wide switch: Wide becomes Medium.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            tile = try container.decode(TodayTile.self, forKey: .tile)
            shown = try container.decodeIfPresent(Bool.self, forKey: .shown) ?? true
            size = try container.decodeIfPresent(Size.self, forKey: .size)
                ?? ((try container.decodeIfPresent(Bool.self, forKey: .wide)) == true ? .medium : .small)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(tile, forKey: .tile)
            try container.encode(size, forKey: .size)
            try container.encode(shown, forKey: .shown)
        }

        private enum Keys: String, CodingKey { case tile, size, shown, wide }
    }

    static let shared = TodayLayout()
    static let standard: [Slot] = [
        Slot(tile: .meeting, size: .medium), Slot(tile: .claude, size: .small), Slot(tile: .tasks, size: .small),
        Slot(tile: .messages, size: .medium), Slot(tile: .habits, size: .small), Slot(tile: .focus, size: .small),
        Slot(tile: .media, size: .medium),
        // The rest start hidden; Customize turns them on.
        Slot(tile: .weather, size: .small, shown: false), Slot(tile: .system, size: .medium, shown: false),
        Slot(tile: .gitlab, size: .medium, shown: false), Slot(tile: .jira, size: .medium, shown: false),
        Slot(tile: .clipboard, size: .medium, shown: false), Slot(tile: .notes, size: .small, shown: false),
        Slot(tile: .money, size: .small, shown: false), Slot(tile: .stands, size: .small, shown: false),
        Slot(tile: .shortcuts, size: .small, shown: false), Slot(tile: .translate, size: .medium, shown: false),
    ]

    @Published var slots: [Slot] { didSet { save() } }

    init() {
        let saved = UserDefaults.standard.data(forKey: "today.layout").flatMap { try? JSONDecoder().decode([Slot].self, from: $0) } ?? []
        // Tiles added in later versions join at the end.
        slots = saved + Self.standard.filter { slot in !saved.contains { $0.tile == slot.tile } }
    }

    func move(_ slot: Slot, by step: Int) {
        guard let index = slots.firstIndex(of: slot), slots.indices.contains(index + step) else { return }
        slots.swapAt(index, index + step)
    }

    func reset() { slots = Self.standard }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(slots), forKey: "today.layout")
    }
}

/// Home tab: one look at the day. Each tile is a window onto another tab's store and opens that tab.
/// The tiles, their order and width are set with Customize.
struct TodayView: View {
    @ObservedObject var model: AppModel
    let services: Services
    @ObservedObject private var layout = TodayLayout.shared
    @State private var customizing = false
    @State private var previewHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Fmt.dayTitle(.now) + " · " + Fmt.day.string(from: .now))
                    .font(Theme.title(14)).foregroundStyle(Theme.primary)
                Spacer()
                if customizing {
                    PillButton(title: "Reset", prominent: false) { layout.reset() }
                    PillButton(title: "Done") { customizing = false }
                } else {
                    IconButton(icon: "slider.horizontal.3", help: "Customize Today") { customizing = true }
                }
            }
            if customizing {
                // The list on the left, a live, scaled-down Today on the right: changes show as you make them.
                GeometryReader { proxy in
                    let listWidth: CGFloat = 300
                    let previewWidth = proxy.size.width - listWidth - 14
                    HStack(alignment: .top, spacing: 14) {
                        editor.frame(width: listWidth)
                        VStack(alignment: .leading, spacing: 6) {
                            SmallCaps("Preview")
                            ScrollView(.vertical) {
                                grid(width: proxy.size.width)
                                    .frame(width: proxy.size.width)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
                                    .scaleEffect(previewWidth / proxy.size.width, anchor: .topLeading)
                                    .frame(width: previewWidth, height: previewHeight * previewWidth / proxy.size.width, alignment: .topLeading)
                                    .allowsHitTesting(false)
                            }
                            .scrollIndicators(.never)
                        }
                    }
                }
            } else {
                GeometryReader { proxy in
                    ScrollView(.vertical) { grid(width: proxy.size.width) }
                        .scrollIndicators(.never)
                }
            }
        }
    }

    private func grid(width: CGFloat) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let units = row.reduce(0) { $0 + $1.size.units }
                let unit = (width - CGFloat(row.count - 1) * 10) / CGFloat(units)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(row) { slot in
                        tile(slot.tile).frame(width: unit * CGFloat(slot.size.units))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Shown tiles packed into rows four units wide (a wide tile takes two); a short row stretches.
    private var rows: [[TodayLayout.Slot]] {
        var rows: [[TodayLayout.Slot]] = [], row: [TodayLayout.Slot] = [], used = 0
        for slot in layout.slots where slot.shown && (slot.tile.tab.map(model.isEnabled) ?? true) {
            let width = slot.size.units
            if used + width > 4 { rows.append(row); row = []; used = 0 }
            row.append(slot)
            used += width
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    @ViewBuilder
    private func tile(_ tile: TodayTile) -> some View {
        switch tile {
        case .meeting: MeetingTile(store: services.calendar) { open(.calendar) }
        case .claude: ClaudeTile(store: services.claude) { open(.claude) }
        case .tasks: TasksTile(store: services.tasks) { open(.tasks) }
        case .messages: MessagesTile(store: services.messages) { open(.messages) }
        case .habits: HabitsTile(store: services.habits) { open(.habits) }
        case .media: MediaTile(store: services.media) { open(.media) }
        case .focus: FocusTile(pomodoro: services.pomodoro)
        case .weather: WeatherTile(store: services.weather) { open(.weather) }
        case .system: SystemTile(monitor: services.system) { open(.system) }
        case .gitlab: GitLabTile(store: services.gitlab) { open(.gitlab) }
        case .jira: JiraTile(store: services.jira) { open(.jira) }
        case .clipboard: ClipboardTile(store: services.clipboard) { open(.clipboard) }
        case .notes: NotesTile(store: services.notes) { open(.notes) }
        case .money: MoneyTile(store: services.finance) { open(.finance) }
        case .stands: StandsTile(store: services.stands, accounts: services.accounts) { open(.environments) }
        case .shortcuts: ShortcutsTile(store: services.shortcuts) { open(.shortcuts) }
        case .translate: TranslateTile(store: services.translate) { open(.translate) }
        }
    }

    private var editor: some View {
        ScrollView(.vertical) {
            VStack(spacing: 4) {
                ForEach(layout.slots) { slot in
                    let index = layout.slots.firstIndex(of: slot) ?? 0
                    let off = slot.tile.tab.map { !model.isEnabled($0) } ?? false
                    HStack(spacing: 7) {
                        Toggle("", isOn: Binding(get: { slot.shown }, set: { layout.slots[index].shown = $0 }))
                            .toggleStyle(.checkbox).labelsHidden()
                        Image(systemName: slot.tile.icon).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Style.current.color(for: slot.tile.tab ?? .habits))
                            .frame(width: 18)
                        Text(slot.tile.title).font(Theme.body(12.5)).foregroundStyle(slot.shown ? Theme.primary : Theme.tertiary)
                            .lineLimit(1)
                            .help(off ? "Its tab is off in Settings" : slot.tile.title)
                        Spacer(minLength: 2)
                        Picker("", selection: Binding(get: { slot.size }, set: { layout.slots[index].size = $0 })) {
                            ForEach(TodayLayout.Size.allCases, id: \.self) { Text($0.title.prefix(1)).tag($0).help($0.title) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 84)
                        .help("Small, Medium or Large: a quarter, half or the whole row")
                        IconButton(icon: "chevron.up", help: "Move up") { layout.move(slot, by: -1) }
                            .opacity(index == 0 ? 0.3 : 1)
                        IconButton(icon: "chevron.down", help: "Move down") { layout.move(slot, by: 1) }
                            .opacity(index == layout.slots.count - 1 ? 0.3 : 1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                    .opacity(off ? 0.5 : 1)
                }
            }
        }
        .scrollIndicators(.never)
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
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: .infinity, alignment: .topLeading)
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
            .frame(maxWidth: .infinity, minHeight: 92, maxHeight: .infinity, alignment: .topLeading)
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
    }
}

// MARK: - More tiles

/// A tile's list line: an optional colour mark, the text, and an optional trailing detail.
private struct TileRow: View {
    let text: String
    var detail: String?
    var mark: Color?
    var action: (() -> Void)?

    var body: some View {
        let line = HStack(spacing: 7) {
            if let mark { RoundedRectangle(cornerRadius: 1.5).fill(mark).frame(width: 3, height: 13) }
            Text(text).font(Theme.caption(12, weight: .regular)).foregroundStyle(Theme.primary).lineLimit(1)
            Spacer(minLength: 4)
            if let detail { Text(detail).font(Theme.caption(11, weight: .medium)).foregroundStyle(Theme.tertiary).lineLimit(1) }
        }
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { line }.buttonStyle(.plain)
        } else {
            line
        }
    }
}

private struct Quiet: View {
    let text: String
    var body: some View { Text(text).font(Theme.caption(12, weight: .regular)).foregroundStyle(Theme.secondary) }
}

private struct WeatherTile: View {
    @ObservedObject var store: WeatherStore
    let open: () -> Void

    var body: some View {
        Tile(tab: .weather, label: store.place.isEmpty ? "Weather" : store.place, open: open) {
            if let now = store.now {
                let sky = WeatherStore.describe(now.code, day: now.isDay)
                HStack(spacing: 8) {
                    Image(systemName: sky.symbol).symbolRenderingMode(.multicolor).font(.system(size: 22))
                    BigNumber(value: "\(Int(now.temperature.rounded()))°")
                }
                Quiet(text: sky.text + (now.high.map { h in now.low.map { " · \(Int(h.rounded()))° / \(Int($0.rounded()))°" } ?? "" } ?? ""))
                    .lineLimit(1)
            } else {
                Quiet(text: store.problem ?? "Loading…")
            }
        }
    }
}

private struct SystemTile: View {
    @ObservedObject var monitor: SystemMonitor
    let open: () -> Void

    var body: some View {
        Tile(tab: .system, open: open) {
            HStack(spacing: 14) {
                ring("CPU", monitor.cpu, Theme.accent)
                ring("RAM", monitor.memoryUsed / max(monitor.memoryTotal, 1), Theme.blue)
                if let battery = monitor.battery {
                    ring(battery.charging ? "Charging" : "Battery", Double(battery.level) / 100,
                         battery.level <= 20 && !battery.charging ? Theme.red : Theme.green)
                }
            }
        }
        // Sampled only while on screen, like the System tab.
        .onAppear(perform: monitor.start)
        .onDisappear(perform: monitor.stop)
    }

    private func ring(_ title: String, _ value: Double, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 4)
                Circle().trim(from: 0, to: min(1, max(0, value)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(Int(value * 100))").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Theme.primary)
            }
            .frame(width: 38, height: 38)
            Text(title).font(Theme.caption(10, weight: .semibold)).foregroundStyle(Theme.tertiary)
        }
    }
}

private struct GitLabTile: View {
    @ObservedObject var store: GitLabStore
    let open: () -> Void

    var body: some View {
        let review = store.requests.filter { $0.role == .review }.count
        Tile(tab: .gitlab, open: open) {
            if store.requests.isEmpty {
                Quiet(text: store.server.isEmpty ? "Not connected" : "No open merge requests")
            } else {
                BigNumber(value: "\(review)", unit: "to review")
                ForEach(store.requests.prefix(3)) { request in
                    TileRow(text: request.title, detail: request.reference,
                            mark: request.pipeline.map { $0 == .failed ? Theme.red : $0 == .success ? Theme.green : Theme.orange }) {
                        store.open(request)
                    }
                }
            }
        }
    }
}

private struct JiraTile: View {
    @ObservedObject var store: JiraStore
    let open: () -> Void

    var body: some View {
        Tile(tab: .jira, open: open) {
            if store.issues.isEmpty {
                Quiet(text: store.site.isEmpty ? "Not connected" : "No issues")
            } else {
                BigNumber(value: "\(store.issues.filter { $0.category != .done }.count)", unit: "open")
                ForEach(store.issues.prefix(3)) { issue in
                    TileRow(text: issue.summary, detail: issue.key,
                            mark: issue.category == .inProgress ? Theme.blue : issue.category == .done ? Theme.green : Theme.tertiary) {
                        NSWorkspace.shared.open(issue.url)
                    }
                }
            }
        }
    }
}

private struct ClipboardTile: View {
    @ObservedObject var store: ClipboardStore
    let open: () -> Void

    var body: some View {
        Tile(tab: .clipboard, open: open) {
            if store.history.isEmpty { Quiet(text: "Nothing copied yet") }
            ForEach(store.history.prefix(4)) { entry in
                TileRow(text: entry.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "),
                        detail: Fmt.ago(entry.copiedAt)) { store.copy(entry.text) }
                    .help("Copy again")
            }
        }
    }
}

private struct NotesTile: View {
    @ObservedObject var store: NotesStore
    let open: () -> Void

    var body: some View {
        Tile(tab: .notes, open: open) {
            if store.notes.isEmpty { Quiet(text: "No notes") }
            ForEach(store.notes.prefix(4)) { note in
                TileRow(text: note.title.isEmpty ? "Untitled" : note.title) {
                    store.select(note.id)
                    open()
                }
            }
        }
        .onAppear { if store.notes.isEmpty { store.refresh() } }
    }
}

private struct MoneyTile: View {
    @ObservedObject var store: FinanceStore
    let open: () -> Void

    var body: some View {
        Tile(tab: .finance, label: "Money · this month", open: open) {
            BigNumber(value: Money.format(store.spent, store.currency))
            Quiet(text: "spent · \(Money.format(store.earned, store.currency)) in").lineLimit(1)
        }
    }
}

private struct StandsTile: View {
    @ObservedObject var store: EnvironmentStore
    @ObservedObject var accounts: AccountStore
    let open: () -> Void

    var body: some View {
        Tile(tab: .environments, open: open) {
            if store.items.isEmpty { Quiet(text: "No stands yet") }
            ForEach(store.items.prefix(4)) { stand in
                TileRow(text: stand.name, detail: "Open") {
                    let account = stand.accountID.flatMap { id in accounts.accounts.first { $0.id == id } }
                    store.open(stand, account: account, accounts: accounts)
                }
                .help("Open the stand and copy its login")
            }
        }
    }
}

private struct ShortcutsTile: View {
    @ObservedObject var store: ShortcutsStore
    let open: () -> Void

    var body: some View {
        Tile(tab: .shortcuts, open: open) {
            let list = store.pinned.isEmpty ? Array(store.names.prefix(4)) : Array(store.pinned.prefix(4))
            if list.isEmpty { Quiet(text: "No shortcuts") }
            ForEach(list, id: \.self) { name in
                TileRow(text: name, detail: state(name)) { store.run(name) }
                    .help("Run")
            }
        }
        .onAppear { if store.names.isEmpty { store.load() } }
    }

    private func state(_ name: String) -> String {
        switch store.states[name] {
        case .running: "Running…"
        case .done: "Done"
        case .failed: "Failed"
        case nil: "Run"
        }
    }
}

private struct TranslateTile: View {
    @ObservedObject var store: TranslateStore
    let open: () -> Void

    var body: some View {
        Tile(tab: .translate, open: open) {
            TextField("Type to translate", text: $store.input)
                .textFieldStyle(.plain)
                .font(Theme.body(13))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
            if !store.output.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.output, forType: .string)
                } label: {
                    Text(store.output).font(Theme.body(13)).foregroundStyle(Theme.primary).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy the translation")
            }
        }
    }
}

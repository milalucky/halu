import SwiftUI

struct RootView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var model: AppModel
    @ObservedObject var notices: NoticeCenter
    @ObservedObject var claude: ClaudeStore
    @ObservedObject var messages: MessagesStore
    let services: Services
    let actions: PanelActions

    private var claudeWaiting: Int { model.isEnabled(.claude) ? claude.attention.count : 0 }
    private var unread: Int { model.isEnabled(.messages) ? messages.unseen : 0 }

    private var display: Display {
        Layout.display(expanded: state.isExpanded, hasNotice: notices.current != nil,
                       attention: claudeWaiting + unread, hasNotch: state.geometry.hasNotch)
    }

    var body: some View {
        let display = display
        let size = Layout.size(display, state.geometry)
        let radii = Layout.radii(display)
        let shape = NotchShape(topRadius: radii.top, bottomRadius: radii.bottom)
        let lifted = display == .expanded || display == .notice

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(lifted ? 0.55 : 0), radius: 22, y: 10)
            content(display)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .opacity(display == .hidden ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: display)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func content(_ display: Display) -> some View {
        switch display {
        case .expanded:
            ExpandedView(model: model, services: services, geometry: state.geometry)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)).animation(.easeOut(duration: 0.22)))
        case .notice:
            if let notice = notices.current {
                NoticeView(notice: notice, top: Layout.noticeTop(state.geometry), notices: notices, actions: actions)
                    .id(notice.id)
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }
        case .badge:
            BadgeView {
                actions.open(services.attentionTab)
            }
                .transition(.opacity)
        case .notch, .hidden:
            Color.clear
        }
    }
}

struct ExpandedView: View {
    @ObservedObject var model: AppModel
    let services: Services
    let geometry: NotchGeometry
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model, awake: services.awake, vpn: services.vpn, speed: services.speed, claude: services.claude, geometry: geometry)
            HStack(spacing: 0) {
                Sidebar(model: model, claude: services.claude, media: services.media, messages: services.messages)
                Rectangle().fill(Theme.hairline).frame(width: 1).padding(.vertical, 6)
                Group {
                    switch model.tab {
                    case .tasks: TasksView(store: services.tasks, speech: services.speech)
                    case .calendar: CalendarView(store: services.calendar)
                    case .claude: ClaudeView(store: services.claude)
                    case .chat: ChatView(store: services.chat)
                    case .shelf: ShelfView(store: services.shelf)
                    case .clipboard: ClipboardView(store: services.clipboard)
                    case .translate: TranslateView(store: services.translate, speech: services.speech)
                    case .compare: CompareView(store: services.compare)
                    case .tools: ToolsView(store: services.tools)
                    case .accounts: AccountsView(store: services.accounts)
                    case .notes: NotesView(store: services.notes)
                    case .media: MediaView(store: services.media)
                    case .messages: MessagesView(store: services.messages)
                    case .jira: JiraView(store: services.jira) { model.tab = .settings }
                    case .settings: IntegrationsView(model: model, jira: services.jira, messages: services.messages)
                    }
                }
                .padding(.leading, 18)
                .padding(.trailing, 20)
                .padding(.top, 4)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            // On Compare a drop anywhere fills the empty side; elsewhere files go to the Shelf.
            if model.tab == .compare {
                services.compare.load(providers: providers)
                return true
            }
            model.tab = .shelf
            services.shelf.add(providers: providers)
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .padding(EdgeInsets(top: Layout.headerHeight(geometry) + 4, leading: 16, bottom: 10, trailing: 16))
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Left wing: the current tab's name. Right wing: Keep Awake, date and time.
struct HeaderBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var awake: AwakeController
    let vpn: VPNController
    let speed: NetworkSpeed
    @ObservedObject var claude: ClaudeStore
    let geometry: NotchGeometry

    var body: some View {
        let wing = (Layout.expandedWidth - (geometry.hasNotch ? geometry.notchSize.width : 0)) / 2 - 20
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                // The mark runs only on the Claude tab, while a session is working.
                HaluMark(size: 15, color: Theme.primary,
                         animating: model.tab == .claude && claude.rows.contains { $0.phase == .working })
                Text("Halu").font(Theme.title(14)).foregroundStyle(Theme.primary)
                Text(model.tab.title)
                    .font(Theme.title(14))
                    .foregroundStyle(Theme.tertiary)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.15), value: model.tab)
            }
            .frame(width: wing, alignment: .leading)
                .padding(.leading, 22)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                SpeedLabel(speed: speed)
                VPNButton(vpn: vpn)
                AwakeButton(awake: awake)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    HStack(spacing: 6) {
                        Text(Fmt.headerDate.string(from: context.date))
                        Text(Fmt.time.string(from: context.date)).monospacedDigit()
                    }
                    .font(Theme.caption(12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .fixedSize()
                }
            }
            .frame(width: wing, alignment: .trailing)
            .padding(.trailing, 20)
        }
        .frame(height: Layout.headerHeight(geometry))
    }
}

/// Vertical tab switcher on the left edge of the panel.
struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var claude: ClaudeStore
    @ObservedObject var media: MediaStore
    @ObservedObject var messages: MessagesStore
    @Namespace private var selection

    /// Media only shows up while something plays or sits paused.
    private var tabs: [Tab] {
        Tab.allCases.filter { tab in
            guard tab != .settings, model.isEnabled(tab) else { return false }
            return tab != .media || media.source != nil || model.tab == .media
        }
    }

    var body: some View {
        VStack(spacing: 1) {
            // Many tabs: slightly shorter buttons, and the list scrolls if it still doesn't fit.
            ScrollView(.vertical) {
                VStack(spacing: 1) {
                    ForEach(tabs) { tab in
                        TabButton(tab: tab, selected: model.tab == tab, height: tabs.count > 11 ? 26 : 30,
                                  dot: (tab == .claude && !claude.attention.isEmpty) || (tab == .messages && messages.unseen > 0),
                                  selection: selection) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.tab = tab }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer(minLength: 4)
            TabButton(tab: .settings, selected: model.tab == .settings, selection: selection) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.tab = .settings }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: tabs)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .frame(width: 58)
    }
}

struct TabButton: View {
    let tab: Tab
    let selected: Bool
    var height: CGFloat = 30
    var dot = false
    let selection: Namespace.ID
    let action: () -> Void
    @State private var hovering = false
    @State private var dwell: DispatchWorkItem?

    var body: some View {
        Button(action: action) {
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .matchedGeometryEffect(id: "tab", in: selection)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card)
                }
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.primary : (hovering ? Theme.secondary : Theme.tertiary))
            }
            .frame(width: 38, height: height)
            .overlay(alignment: .topTrailing) {
                if dot {
                    Circle().fill(Theme.orange).frame(width: 6, height: 6).offset(x: -6, y: 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .onHover { inside in
            hovering = inside
            dwell?.cancel()
            // Switch on hover only after the pointer rests on the icon.
            if inside && !selected {
                let work = DispatchWorkItem { action() }
                dwell = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
            }
        }
    }
}

/// One tap keeps the Mac awake; the cup steams while it's on. Right-click for a time limit.
struct AwakeButton: View {
    @ObservedObject var awake: AwakeController
    @State private var hovering = false

    var body: some View {
        Button(action: awake.toggle) {
            // Icon only, the steam shows it's on; the time left is in the tooltip.
            Image(systemName: awake.isOn ? "cup.and.heat.waves.fill" : "cup.and.saucer")
                .font(.system(size: 12, weight: .semibold))
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: awake.isOn)
                .symbolEffect(.bounce, value: awake.isOn)
            .foregroundStyle(awake.isOn ? Theme.orange : (hovering ? Theme.secondary : Theme.tertiary))
            .frame(width: 26, height: 22)
            .background(Capsule().fill(awake.isOn ? Theme.orange.opacity(0.15) : (hovering ? Theme.card : .clear)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(awake.isOn ? "Mac and display stay awake (\(label(now: .now))) · click to let it sleep" : "Keep Mac awake")
        .contextMenu {
            Button("Keep awake for 1 hour") { awake.start(for: 3600) }
            Button("Keep awake for 3 hours") { awake.start(for: 3 * 3600) }
            Button("Keep awake until turned off") { awake.start() }
            if awake.isOn {
                Divider()
                Button("Let Mac sleep") { awake.stop() }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: awake.isOn)
    }

    private func label(now: Date) -> String {
        guard let until = awake.until else { return "until turned off" }
        let minutes = max(0, Int(until.timeIntervalSince(now) / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

/// Collapsed notch with Halu's mark beside it, lit orange: something is waiting (unread messages or
/// Claude). No counts, nothing else.
struct BadgeView: View {
    let onTap: () -> Void
    @State private var glow = false

    var body: some View {
        HStack(spacing: 0) {
            HaluMark(size: 14, color: Theme.orange, animating: false)
                .shadow(color: Theme.orange.opacity(glow ? 0.7 : 0.15), radius: glow ? 5 : 2)
                .frame(width: Layout.badgeWing)
            Spacer(minLength: 0)
            Color.clear.frame(width: Layout.badgeWing)
        }
        .padding(.horizontal, Layout.flare)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}

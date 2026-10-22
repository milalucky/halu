import SwiftUI

struct RootView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var model: AppModel
    @ObservedObject var notices: NoticeCenter
    @ObservedObject var live: LiveCenter
    @ObservedObject var requests: ClaudeRequests
    @ObservedObject var claude: ClaudeStore
    @ObservedObject var messages: MessagesStore
    let services: Services
    let actions: PanelActions

    @State private var gulp = false

    private var claudeWaiting: Int { model.isEnabled(.claude) ? claude.attention.count : 0 }
    private var unread: Int { model.isEnabled(.messages) ? messages.unseen : 0 }

    private var display: Display {
        Layout.display(expanded: state.isExpanded, hasRequest: requests.current != nil, hasNotice: notices.current != nil, live: live.activity != nil,
                       attention: claudeWaiting + unread, hasNotch: state.geometry.hasNotch)
    }

    var body: some View {
        let display = display
        let size = Layout.size(display, state.geometry)
        let radii = Layout.radii(display)
        let shape = NotchShape(topRadius: radii.top, bottomRadius: radii.bottom)
        let lifted = display == .expanded || display == .notice || display == .request

        ZStack(alignment: .top) {
            PanelBackground(shape: shape, style: model.style, open: lifted, headerHeight: Layout.headerHeight(state.geometry))
                .shadow(color: .black.opacity(lifted ? 0.55 : 0), radius: 22, y: 10)
            if lifted && model.style.glows {
                NeonRim(shape: shape)
            }
            content(display)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .opacity(display == .hidden ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .scaleEffect(gulp ? 1.07 : 1, anchor: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.74), value: display)
        .onChange(of: model.gulps) {
            // A file dropped on the notch: it swallows it.
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { gulp = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { gulp = false }
            }
        }
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
        case .request:
            if let request = requests.current {
                ClaudeRequestView(request: request, top: Layout.noticeTop(state.geometry), requests: requests)
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }
        case .live:
            if let activity = live.activity {
                LiveView(activity: activity, attention: claudeWaiting + unread > 0, pomodoro: services.pomodoro,
                         shape: NotchShape(topRadius: Layout.radii(.live).top, bottomRadius: Layout.radii(.live).bottom),
                         calendar: services.calendar)
                    .transition(.opacity)
            }
        case .notch, .hidden:
            Color.clear
        }
    }
}

/// The selected tab's screen; the same in the notch panel and the full window.
struct TabContent: View {
    @ObservedObject var model: AppModel
    let services: Services

    var body: some View {
        switch model.tab {
        case .tasks: TasksView(store: services.tasks, speech: services.speech)
        case .calendar: CalendarView(store: services.calendar)
        case .claude: ClaudeView(store: services.claude)
        case .chat: ChatView(store: services.chat)
        case .finance: FinanceView(store: services.finance)
        case .weather: WeatherView(weather: services.weather)
        case .clipboard: ClipboardTab(clipboard: services.clipboard, shelf: services.shelf)
        case .translate: TranslateView(store: services.translate, speech: services.speech)
        case .tools: ToolsView(store: services.tools, compare: services.compare, screen: services.screenTools, market: services.market)
        case .accounts: AccountsView(store: services.accounts)
        case .notes: NotesView(store: services.notes)
        case .media: MediaView(store: services.media)
        case .messages: MessagesView(store: services.messages)
        case .jira: JiraView(store: services.jira) { model.tab = .settings }
        case .gitlab: GitLabView(store: services.gitlab) { model.tab = .settings }
        case .settings: IntegrationsView(model: model, jira: services.jira, gitlab: services.gitlab, messages: services.messages)
        }
    }
}

/// The open panel's backdrop for the theme. Collapsed states are always black, to melt into the notch.
struct PanelBackground: View {
    let shape: NotchShape
    let style: Style
    let open: Bool
    let headerHeight: CGFloat

    var body: some View {
        if !open {
            shape.fill(Color.black)
        } else {
            switch style {
            case .minimal:
                shape.fill(Color.black)
            case .playful:
                // A soft wash of the tab's colour from the top-left corner.
                ZStack {
                    shape.fill(Color.black)
                    shape.fill(RadialGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0.06), .clear],
                                              center: .init(x: 0.1, y: 0.15), startRadius: 0, endRadius: 520))
                    shape.fill(RadialGradient(colors: [Theme.accent.opacity(0.1), .clear], center: .init(x: 0.95, y: 1), startRadius: 0, endRadius: 360))
                }
                .animation(.easeInOut(duration: 0.5), value: Theme.accent.description)
            case .neon:
                ZStack {
                    shape.fill(LinearGradient(colors: [Color(red: 0.03, green: 0.02, blue: 0.08), Color(red: 0.01, green: 0.01, blue: 0.03)],
                                              startPoint: .top, endPoint: .bottom))
                    shape.fill(RadialGradient(colors: [Theme.accent.opacity(0.16), .clear], center: .bottom, startRadius: 0, endRadius: 420))
                }
            case .glass:
                ZStack(alignment: .top) {
                    Color.clear.modifier(GlassFill(shape: shape))
                    shape.fill(RadialGradient(colors: [Theme.accent.opacity(0.18), .clear], center: .init(x: 0.1, y: 0.2), startRadius: 0, endRadius: 480))
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7), .init(color: .black.opacity(0), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: headerHeight + 10)
                        .clipShape(shape)
                }
            }
        }
    }
}

/// Neon: a gradient rim that slowly travels round the panel.
struct NeonRim: View {
    let shape: NotchShape

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) / 6
            let gradient = AngularGradient(colors: [Theme.accent, Color(red: 1, green: 0.2, blue: 0.75), Color(red: 0.2, green: 0.85, blue: 1), Theme.accent],
                                           center: .center, angle: .degrees(turn * 360))
            shape.stroke(gradient, lineWidth: 1.5)
                .shadow(color: Theme.accent.opacity(0.7), radius: 6)
                .shadow(color: Color(red: 1, green: 0.2, blue: 0.75).opacity(0.35), radius: 14)
        }
        .allowsHitTesting(false)
    }
}

private struct GlassFill: ViewModifier {
    let shape: NotchShape

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(Color.black.opacity(0.4)), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .background(shape.fill(Color.black.opacity(0.5)))
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
                .environment(\.colorScheme, .dark)
            HStack(spacing: 0) {
                Sidebar(model: model, claude: services.claude, media: services.media, messages: services.messages, gitlab: services.gitlab)
                Rectangle().fill(Theme.hairline).frame(width: 1).padding(.vertical, 6)
                TabContent(model: model, services: services)
                .id(model.style)
                .padding(.leading, 18)
                .padding(.trailing, 20)
                .padding(.top, 4)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            // On Tools → Compare a drop anywhere fills the empty side; elsewhere files go to the Shelf.
            model.gulps += 1
            if model.tab == .tools && services.tools.mode == .compare {
                services.compare.load(providers: providers)
                return true
            }
            model.tab = .clipboard
            services.clipboard.mode = .shelf
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

/// Left wing: Halu, the current tab, weather and time. Right wing: Claude usage, speed and quick buttons.
struct HeaderBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var awake: AwakeController
    let vpn: VPNController
    let speed: NetworkSpeed
    @ObservedObject var claude: ClaudeStore
    let geometry: NotchGeometry

    @State private var logoSpin: Double = 0

    var body: some View {
        let wing = (Layout.expandedWidth - (geometry.hasNotch ? geometry.notchSize.width : 0)) / 2 - 20
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                // The mark runs only on the Claude tab, while a session is working.
                Button { Services.shared.openWindow() } label: {
                    HStack(spacing: 8) {
                        HaluMark(size: 15, color: Theme.primary,
                                 animating: model.tab == .claude && claude.rows.contains { $0.phase == .working })
                            // Says hello when you point at it.
                            .rotationEffect(.degrees(logoSpin))
                            .onHover { inside in
                                guard inside else { return }
                                withAnimation(.spring(response: 0.6, dampingFraction: 0.55)) { logoSpin += 360 }
                            }
                        Text("Halu").font(Theme.title(14)).foregroundStyle(Theme.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Halu in a window")
                Text(model.tab.title)
                    .font(Theme.title(14))
                    .foregroundStyle(model.style == .minimal ? Theme.tertiary : Style.current.color(for: model.tab).opacity(0.85))
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.15), value: model.tab)
                    .lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 4)
                WeatherPill(weather: Services.shared.weather, model: model)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(Fmt.time.string(from: context.date)).monospacedDigit()
                        .font(Theme.caption(12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize()
                        .help(Fmt.day.string(from: context.date))
                }
            }
            .frame(width: wing, alignment: .leading)
                .padding(.leading, 22)

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                ClaudeUsagePill(requests: Services.shared.claudeRequests)
                SpeedLabel(speed: speed)
                ChatButton(model: model)
                RecordButton(recordly: Services.shared.recordly)
                PomodoroButton(pomodoro: Services.shared.pomodoro)
                VPNButton(vpn: vpn)
                AwakeButton(awake: awake)
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
    @ObservedObject var gitlab: GitLabStore
    @Namespace private var selection

    /// Media only shows up while something plays or sits paused.
    private var tabs: [Tab] {
        model.order.filter { tab in
            guard tab != .settings, tab != .chat, tab != .weather, model.isEnabled(tab) else { return false }
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
                                  dot: (tab == .claude && !claude.attention.isEmpty) || (tab == .messages && messages.unseen > 0)
                                      || (tab == .gitlab && gitlab.newComments > 0),
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
                    let tint = Style.current.color(for: tab)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Style.current == .minimal ? Color.white.opacity(0.12) : tint.opacity(Style.current.glows ? 0.24 : 0.18))
                        .shadow(color: Style.current.glows ? tint.opacity(0.7) : .clear, radius: 8)
                        .matchedGeometryEffect(id: "tab", in: selection)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card)
                }
                Group {
                    if tab == .claude {
                        ClaudeMark()
                            .stroke(style: StrokeStyle(lineWidth: selected ? 1.9 : 1.6, lineCap: .round))
                            .frame(width: 15, height: 15)
                    } else {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    }
                }
                .foregroundStyle(selected ? (Style.current == .minimal ? Theme.primary : Style.current.color(for: tab))
                                          : Style.current == .playful ? Style.current.color(for: tab).opacity(hovering ? 0.9 : 0.55)
                                          : (hovering ? Theme.secondary : Theme.tertiary))
                .shadow(color: selected && Style.current.glows ? Style.current.color(for: tab) : .clear, radius: 4)
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
            .headerButton(active: awake.isOn, tint: Theme.orange, hovering: hovering)
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

/// A burst of uneven rays, in the spirit of Claude's mark, drawn in the sidebar's own monochrome style.
struct ClaudeMark: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        // Ray lengths go round the circle; the unevenness is what makes it read as hand-drawn.
        let lengths: [CGFloat] = [1.0, 0.72, 0.9, 0.66, 0.97, 0.75, 0.86, 0.62, 1.0, 0.7, 0.92, 0.68]
        var path = Path()
        for (index, length) in lengths.enumerated() {
            let angle = CGFloat(index) / CGFloat(lengths.count) * 2 * .pi - .pi / 2
            let inner = radius * 0.22, outer = radius * length
            path.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
            path.addLine(to: CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
        }
        return path
    }
}

import AppKit
import SwiftUI

/// One panel per display. A light pointer poll (30 Hz, AppKit only) drives hover-to-open,
/// leave-to-close and click-through, which keeps working during drags and menu tracking.
@MainActor
final class NotchController {
    @MainActor
    private final class ScreenPanel {
        let window: NotchPanel
        let state: PanelState
        let actions = PanelActions()
        var hoverSince: Date?
        var leaveSince: Date?
        /// Opened from the menu bar: stays open until the pointer has visited and left, or a click lands outside.
        var sticky = false
        var wasInside = false

        init(window: NotchPanel, state: PanelState) {
            self.window = window
            self.state = state
        }
    }

    private let services: Services
    private var panels: [CGDirectDisplayID: ScreenPanel] = [:]
    private var timer: Timer?
    private var idleDragCount = NSPasteboard(name: .drag).changeCount

    private let hoverDelay: TimeInterval = 0.12
    private let leaveDelay: TimeInterval = 0.3

    init(services: Services) {
        self.services = services
        rebuildPanels()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func openOnPointerScreen() {
        let point = NSEvent.mouseLocation
        let panel = panels.values.first { $0.state.geometry.screenFrame.contains(point) } ?? panels.values.first
        guard let panel else { return }
        expand(panel, tab: nil)
        panel.sticky = true
    }

    private func rebuildPanels() {
        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            seen.insert(id)
            let geometry = NotchGeometry.of(screen)
            if let existing = panels[id] {
                existing.state.geometry = geometry
                existing.window.setFrame(Self.frame(for: geometry), display: true)
            } else {
                panels[id] = makePanel(geometry: geometry)
            }
        }
        for (id, panel) in panels where !seen.contains(id) {
            panel.window.orderOut(nil)
            panels[id] = nil
        }
    }

    private func makePanel(geometry: NotchGeometry) -> ScreenPanel {
        let frame = Self.frame(for: geometry)
        let window = NotchPanel(frame: frame)
        let panel = ScreenPanel(window: window, state: PanelState(geometry: geometry))
        panel.actions.open = { [weak self, weak panel] tab in
            guard let self, let panel else { return }
            self.expand(panel, tab: tab)
        }
        panel.actions.collapse = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.collapse(panel)
        }
        let root = RootView(state: panel.state, model: services.model, notices: services.notices,
                            claude: services.claude, messages: services.messages, services: services, actions: panel.actions)
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: frame.size)
        window.contentView = host
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        return panel
    }

    private static func frame(for g: NotchGeometry) -> CGRect {
        let size = Layout.windowSize
        return CGRect(x: g.screenFrame.midX - size.width / 2, y: g.screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func display(of panel: ScreenPanel) -> Display {
        Layout.display(expanded: panel.state.isExpanded, hasNotice: services.notices.current != nil,
                       attention: services.attentionCount, hasNotch: panel.state.geometry.hasNotch)
    }

    private func expand(_ panel: ScreenPanel, tab: Tab?) {
        if let tab { services.model.tab = tab }
        for other in panels.values where other !== panel && other.state.isExpanded { collapse(other) }
        panel.hoverSince = nil
        panel.leaveSince = nil
        panel.sticky = false
        panel.wasInside = false
        if !panel.state.isExpanded { panel.state.isExpanded = true }
    }

    private func collapse(_ panel: ScreenPanel) {
        guard panel.state.isExpanded else { return }
        panel.state.isExpanded = false
        panel.leaveSince = nil
        panel.sticky = false
        if panel.window.isKeyWindow {
            // Hand keyboard focus back to whatever app the user was in.
            panel.window.orderOut(nil)
            panel.window.orderFrontRegardless()
        }
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        let buttons = NSEvent.pressedMouseButtons
        let dragCount = NSPasteboard(name: .drag).changeCount
        if buttons == 0 { idleDragCount = dragCount }
        let isFileDrag = buttons & 1 != 0 && dragCount != idleDragCount
        let now = Date()
        var hoveringNotice = false

        for panel in panels.values {
            let g = panel.state.geometry
            let current = display(of: panel)

            if panel.state.isExpanded {
                let area = g.rect(Layout.size(.expanded, g)).insetBy(dx: -14, dy: -14)
                if area.contains(point) {
                    panel.wasInside = true
                    panel.leaveSince = nil
                } else if panel.sticky && !panel.wasInside {
                    if buttons != 0 { collapse(panel) }
                } else if buttons != 0 {
                    // Dragging something out of the panel: stay open until the drop.
                    panel.leaveSince = nil
                } else {
                    let since = panel.leaveSince ?? now
                    panel.leaveSince = since
                    if now.timeIntervalSince(since) >= leaveDelay { collapse(panel) }
                }
            } else if current != .notice {
                let triggerWidth = current == .badge ? Layout.size(.badge, g).width : nil
                if g.isInTrigger(point, width: triggerWidth) {
                    if isFileDrag {
                        expand(panel, tab: .shelf)
                    } else if buttons == 0 {
                        let since = panel.hoverSince ?? now
                        panel.hoverSince = since
                        // Hovering the indicators opens straight to what they point at.
                        if now.timeIntervalSince(since) >= hoverDelay {
                            expand(panel, tab: current == .badge ? services.attentionTab : nil)
                        }
                    }
                } else {
                    panel.hoverSince = nil
                }
            }

            let shown = display(of: panel)
            let hit = Layout.hitRect(shown, g)?.insetBy(dx: 0, dy: -2).contains(point) ?? false
            if panel.window.ignoresMouseEvents == hit { panel.window.ignoresMouseEvents = !hit }
            if shown == .notice && hit { hoveringNotice = true }
        }
        services.notices.isHovered = hoveringNotice
    }
}

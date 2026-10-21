import AppKit
import SwiftUI

/// Borderless, non-activating panel pinned over the menu bar. It can take keyboard
/// focus for text fields without pulling Halu to the front.
final class NotchPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Keep the frame over the menu bar instead of letting AppKit push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PanelState: ObservableObject {
    @Published var geometry: NotchGeometry
    @Published var isExpanded = false

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }
}

/// Callbacks from the SwiftUI tree back to the controller.
@MainActor
final class PanelActions {
    var open: (Tab?) -> Void = { _ in }
    var collapse: () -> Void = {}
}

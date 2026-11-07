import SwiftUI

/// What a display's panel is showing right now.
enum Display: Equatable {
    case hidden, notch, badge, live, notice, request, expanded

    var isInteractive: Bool { self != .hidden && self != .notch }
}

enum Layout {
    /// The transparent window the panel is drawn in: room for the widest panel and its shadow.
    static let windowSize = CGSize(width: 1000, height: 640)
    /// The open panel's size, from Settings → Panel size (AppModel keeps these in step).
    static var expandedWidth: CGFloat = 680
    static var contentHeight: CGFloat = 404
    static let noticeWidth: CGFloat = 440
    /// The Claude card's measured content height (a question with several described options needs more
    /// than the default); RootView keeps it current.
    static var requestContentHeight: CGFloat = 0
    /// The concave flare at the top corners; the body of the shape is inset by it.
    static let flare: CGFloat = 8
    /// Width of each side of the collapsed notch when it carries indicators.
    static let badgeWing: CGFloat = 30
    /// Width of each side while a meeting countdown or timer is live.
    static let liveWing: CGFloat = 58

    static func display(expanded: Bool, hasRequest: Bool = false, hasNotice: Bool, live: Bool, attention: Int, hasNotch: Bool) -> Display {
        if expanded { return .expanded }
        if hasRequest { return .request }
        if hasNotice { return .notice }
        if live { return .live }
        if attention > 0 { return .badge }
        return hasNotch ? .notch : .hidden
    }

    static func headerHeight(_ g: NotchGeometry) -> CGFloat {
        g.hasNotch ? max(g.notchSize.height, 32) : 38
    }

    static func noticeTop(_ g: NotchGeometry) -> CGFloat {
        g.hasNotch ? g.notchSize.height : 6
    }

    static func size(_ display: Display, _ g: NotchGeometry) -> CGSize {
        switch display {
        case .hidden:
            return CGSize(width: g.notchSize.width * 0.7, height: 8)
        case .notch:
            return CGSize(width: g.notchSize.width + flare * 2, height: g.notchSize.height)
        case .badge:
            return CGSize(width: g.notchSize.width + flare * 2 + badgeWing * 2, height: g.hasNotch ? g.notchSize.height : 28)
        case .live:
            // A little taller than the camera housing, so the glowing line along the bottom shows under it.
            return CGSize(width: g.notchSize.width + flare * 2 + liveWing * 2, height: g.hasNotch ? g.notchSize.height + 9 : 28)
        case .notice:
            return CGSize(width: noticeWidth, height: noticeTop(g) + 70)
        case .request:
            return CGSize(width: 540, height: min(windowSize.height - 40, max(noticeTop(g) + 176, requestContentHeight)))
        case .expanded:
            return CGSize(width: expandedWidth, height: headerHeight(g) + contentHeight)
        }
    }

    static func radii(_ display: Display) -> (top: CGFloat, bottom: CGFloat) {
        switch display {
        case .expanded: (flare, 28)
        case .notice, .request: (flare, 24)
        case .badge, .live: (flare, 14)
        case .notch, .hidden: (flare, 12)
        }
    }

    /// Screen rect that should catch the mouse, or nil when clicks pass through.
    static func hitRect(_ display: Display, _ g: NotchGeometry) -> CGRect? {
        display.isInteractive ? g.rect(size(display, g)) : nil
    }
}

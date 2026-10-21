import SwiftUI

/// What a display's panel is showing right now.
enum Display: Equatable {
    case hidden, notch, badge, notice, expanded

    var isInteractive: Bool { self == .badge || self == .notice || self == .expanded }
}

enum Layout {
    static let windowSize = CGSize(width: 760, height: 540)
    static let expandedWidth: CGFloat = 640
    static let contentHeight: CGFloat = 372
    static let noticeWidth: CGFloat = 440
    /// The concave flare at the top corners; the body of the shape is inset by it.
    static let flare: CGFloat = 8

    static func display(expanded: Bool, hasNotice: Bool, attention: Int, hasNotch: Bool) -> Display {
        if expanded { return .expanded }
        if hasNotice { return .notice }
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
            return CGSize(width: g.notchSize.width + flare * 2 + 84, height: g.hasNotch ? g.notchSize.height : 28)
        case .notice:
            return CGSize(width: noticeWidth, height: noticeTop(g) + 70)
        case .expanded:
            return CGSize(width: expandedWidth, height: headerHeight(g) + contentHeight)
        }
    }

    static func radii(_ display: Display) -> (top: CGFloat, bottom: CGFloat) {
        switch display {
        case .expanded: (flare, 28)
        case .notice: (flare, 24)
        case .badge: (flare, 14)
        case .notch, .hidden: (flare, 12)
        }
    }

    /// Screen rect that should catch the mouse, or nil when clicks pass through.
    static func hitRect(_ display: Display, _ g: NotchGeometry) -> CGRect? {
        display.isInteractive ? g.rect(size(display, g)) : nil
    }
}

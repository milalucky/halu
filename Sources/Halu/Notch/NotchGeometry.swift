import AppKit

/// Where the notch is on one display. Displays without a notch get a virtual one
/// at the top centre, so the panel opens the same way on an external monitor.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchSize: CGSize
    var hasNotch: Bool

    static func of(_ screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let size = CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
            return NotchGeometry(screenFrame: frame, notchSize: size, hasNotch: true)
        }
        let menuBar = frame.maxY - screen.visibleFrame.maxY
        let height = menuBar > 4 ? menuBar : 24
        return NotchGeometry(screenFrame: frame, notchSize: CGSize(width: 200, height: height), hasNotch: false)
    }

    /// A rect of the given size hanging from the top centre, in screen coordinates.
    func rect(_ size: CGSize) -> CGRect {
        CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Pointer zone that opens the panel: the notch itself plus a little slack.
    func isInTrigger(_ point: CGPoint, width: CGFloat? = nil) -> Bool {
        let zoneWidth = (width ?? notchSize.width) + 16
        let zone = rect(CGSize(width: zoneWidth, height: notchSize.height))
        return point.x >= zone.minX && point.x <= zone.maxX && point.y >= zone.minY && point.y <= screenFrame.maxY + 1
    }
}

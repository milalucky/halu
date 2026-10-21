import AppKit
import ScreenCaptureKit

/// Pick a colour anywhere on screen, and measure things in pixels.
@MainActor
final class ScreenTools: ObservableObject {
    /// The last colour picked, as #RRGGBB; also copied.
    @Published private(set) var color: NSColor?
    @Published private(set) var lastMeasure: String?

    private var ruler: RulerWindow?

    var hex: String? {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    /// macOS's own magnifying loupe; the picked colour's hex is copied.
    func pickColor() {
        NSColorSampler().show { [weak self] picked in
            guard let picked else { return }
            MainActor.assumeIsolated {
                self?.color = picked
                if let hex = self?.hex { Self.copy(hex) }
            }
        }
    }

    @Published private(set) var needsScreenAccess = false

    /// A see-through layer over a still picture of the screen. Hovering measures the gap around the
    /// pointer to the nearest edges (spacing between elements); dragging measures a box. Esc closes.
    /// Seeing the edges takes Screen Recording permission; without it only the box works.
    func showRuler() {
        ruler?.close()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        if !CGPreflightScreenCaptureAccess() {
            needsScreenAccess = !CGRequestScreenCaptureAccess()
        }
        Task {
            let snapshot = CGPreflightScreenCaptureAccess() ? await Self.capture(screen) : nil
            let window = RulerWindow(screen: screen, snapshot: snapshot) { [weak self] text in
                self?.lastMeasure = text
                Self.copy(text)
            }
            ruler = window
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The screen as it is now, at full pixel resolution, without Halu's own windows.
    private static func capture(_ screen: NSScreen) async -> CGImage? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
        configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

final class RulerWindow: NSWindow {
    init(screen: NSScreen, snapshot: CGImage?, onMeasure: @escaping (String) -> Void) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = RulerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.scale = screen.backingScaleFactor
        view.snapshot = snapshot.flatMap(Pixels.init)
        view.onMeasure = onMeasure
        view.onClose = { [weak self] in self?.close() }
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

/// Read access to a screenshot's pixels, to find where one element ends and the next begins.
private struct Pixels {
    let width: Int, height: Int
    let data: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        data = buffer
    }

    /// Pixel (x, y) from the top-left, as one comparable value.
    func color(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    /// Walks from (x, y) in a direction until the colour changes; returns how many pixels it went.
    func run(fromX x: Int, y: Int, dx: Int, dy: Int, tolerance: Int = 18) -> Int {
        let start = color(x, y)
        var step = 0
        var cx = x, cy = y
        while true {
            let nx = cx + dx, ny = cy + dy
            guard nx >= 0, ny >= 0, nx < width, ny < height else { return step }
            let c = color(nx, ny)
            if abs(c.0 - start.0) + abs(c.1 - start.1) + abs(c.2 - start.2) > tolerance { return step }
            cx = nx; cy = ny; step += 1
        }
    }
}

private final class RulerView: NSView {
    var scale: CGFloat = 2
    var snapshot: Pixels?
    var onMeasure: (String) -> Void = { _ in }
    var onClose: () -> Void = {}
    private var start: NSPoint?
    private var end: NSPoint?
    private var pointer: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose() } // Esc
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A click with a measurement on screen starts a new one; a click without dragging closes.
        start = point
        end = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        end = convert(event.locationInWindow, from: nil)
        pointer = end
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start, let end else { return }
        if abs(end.x - start.x) < 2 && abs(end.y - start.y) < 2 {
            // A click copies the gap under the pointer (or closes when there's nothing to measure).
            if let gap {
                let width = Int((gap.left + gap.right + 1 / scale).rounded()), height = Int((gap.up + gap.down + 1 / scale).rounded())
                onMeasure("\(width) × \(height)")
                self.start = nil
                self.end = nil
            } else {
                onClose()
            }
            return
        }
        onMeasure(label(for: rect(start, end)))
    }

    private func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Points as CSS sees them, and the real pixels on this display.
    private func label(for rect: NSRect) -> String {
        let w = Int(rect.width.rounded()), h = Int(rect.height.rounded())
        return scale > 1 ? "\(w) × \(h) pt (\(Int(rect.width * scale)) × \(Int(rect.height * scale)) px)" : "\(w) × \(h) px"
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.12).setFill()
        bounds.fill()
        let accent = NSColor(red: 1, green: 0.4, blue: 0.5, alpha: 1)

        if let snapshot, let image = snapshotImage {
            image.draw(in: bounds)
            NSColor.black.withAlphaComponent(0.08).setFill()
            bounds.fill()
            _ = snapshot
        }
        if let pointer, start == nil || start == end {
            if let snapshot {
                drawGap(around: pointer, in: snapshot, color: accent)
            } else {
                accent.withAlphaComponent(0.6).setStroke()
                let guides = NSBezierPath()
                guides.move(to: NSPoint(x: 0, y: pointer.y)); guides.line(to: NSPoint(x: bounds.maxX, y: pointer.y))
                guides.move(to: NSPoint(x: pointer.x, y: 0)); guides.line(to: NSPoint(x: pointer.x, y: bounds.maxY))
                guides.lineWidth = 1
                guides.stroke()
                tag("\(Int(pointer.x)), \(Int(bounds.height - pointer.y))", at: NSPoint(x: pointer.x + 10, y: pointer.y + 10))
            }
        }
        if let start, let end, start != end {
            let box = rect(start, end)
            accent.withAlphaComponent(0.15).setFill()
            box.fill()
            accent.setStroke()
            let path = NSBezierPath(rect: box)
            path.lineWidth = 1
            path.stroke()
            tag(label(for: box), at: NSPoint(x: box.midX - 60, y: box.maxY + 8))
        }
        let hint = snapshot == nil
            ? "Drag to measure · allow Screen Recording for Halu to measure gaps · Esc to close"
            : "Point into a gap to see the spacing · click copies it · drag for a box · Esc to close"
        tag(hint, at: NSPoint(x: bounds.midX - 250, y: 40))
    }

    /// The still screenshot to draw under the guides, so nothing moves while measuring.
    private lazy var snapshotImage: NSImage? = {
        guard let snapshot else { return nil }
        var data = snapshot.data
        guard let provider = CGDataProvider(data: Data(bytes: &data, count: data.count) as CFData),
              let image = CGImage(width: snapshot.width, height: snapshot.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: snapshot.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: bounds.size)
    }()

    /// The current gap: distances from the pointer to the nearest edges left, right, up and down.
    private var gap: (left: CGFloat, right: CGFloat, up: CGFloat, down: CGFloat)?

    private func drawGap(around point: NSPoint, in pixels: Pixels, color: NSColor) {
        let px = Int(point.x * scale), py = Int((bounds.height - point.y) * scale)
        guard px >= 0, py >= 0, px < pixels.width, py < pixels.height else { return }
        let left = CGFloat(pixels.run(fromX: px, y: py, dx: -1, dy: 0)) / scale
        let right = CGFloat(pixels.run(fromX: px, y: py, dx: 1, dy: 0)) / scale
        let up = CGFloat(pixels.run(fromX: px, y: py, dx: 0, dy: -1)) / scale
        let down = CGFloat(pixels.run(fromX: px, y: py, dx: 0, dy: 1)) / scale
        gap = (left, right, up, down)
        color.setStroke()
        let lines = NSBezierPath()
        lines.lineWidth = 1
        // Horizontal span (edge to edge) and vertical span, in view coordinates (y grows upward).
        lines.move(to: NSPoint(x: point.x - left, y: point.y)); lines.line(to: NSPoint(x: point.x + right + 1 / scale, y: point.y))
        lines.move(to: NSPoint(x: point.x, y: point.y + up)); lines.line(to: NSPoint(x: point.x, y: point.y - down - 1 / scale))
        for (x, y, vertical) in [(point.x - left, point.y, true), (point.x + right, point.y, true), (point.x, point.y + up, false), (point.x, point.y - down, false)] {
            if vertical {
                lines.move(to: NSPoint(x: x, y: y - 5)); lines.line(to: NSPoint(x: x, y: y + 5))
            } else {
                lines.move(to: NSPoint(x: x - 5, y: y)); lines.line(to: NSPoint(x: x + 5, y: y))
            }
        }
        lines.stroke()
        let width = Int((left + right + 1 / scale).rounded()), height = Int((up + down + 1 / scale).rounded())
        tag("\(width)", at: NSPoint(x: point.x - left + (left + right) / 2 - 12, y: point.y + 6))
        tag("\(height)", at: NSPoint(x: point.x + 6, y: point.y - down + (up + down) / 2 - 8))
        tag("\(width) × \(height)", at: NSPoint(x: point.x + 14, y: point.y - 30))
    }

    private func tag(_ text: String, at point: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = NSRect(x: point.x, y: point.y, width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 7, y: box.minY + 3), withAttributes: attributes)
    }
}

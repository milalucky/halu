import AppKit

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

    /// A see-through layer over the screen: drag to measure, the size is copied, Esc closes.
    func showRuler() {
        ruler?.close()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let window = RulerWindow(screen: screen) { [weak self] text in
            self?.lastMeasure = text
            Self.copy(text)
        }
        ruler = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

final class RulerWindow: NSWindow {
    init(screen: NSScreen, onMeasure: @escaping (String) -> Void) {
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
        view.onMeasure = onMeasure
        view.onClose = { [weak self] in self?.close() }
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

private final class RulerView: NSView {
    var scale: CGFloat = 2
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
            onClose()
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

        if let pointer, start == nil || start == end {
            accent.withAlphaComponent(0.6).setStroke()
            let guides = NSBezierPath()
            guides.move(to: NSPoint(x: 0, y: pointer.y)); guides.line(to: NSPoint(x: bounds.maxX, y: pointer.y))
            guides.move(to: NSPoint(x: pointer.x, y: 0)); guides.line(to: NSPoint(x: pointer.x, y: bounds.maxY))
            guides.lineWidth = 1
            guides.stroke()
            tag("\(Int(pointer.x)), \(Int(bounds.height - pointer.y))", at: NSPoint(x: pointer.x + 10, y: pointer.y + 10))
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
        tag("Drag to measure · the size is copied · Esc or click to close", at: NSPoint(x: bounds.midX - 190, y: 40))
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

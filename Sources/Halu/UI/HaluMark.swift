import AppKit
import SwiftUI

/// The Halu mark: an open ring with a moon-like dot in its gap.
/// When `animating`, the dot orbits and the ring follows it like a snake, stretching and
/// shrinking as it chases — used as the loader and the "still working" indicator.
struct HaluMark: View {
    var size: CGFloat = 18
    var color: Color = Theme.primary
    var animating = false
    /// Laps per second while animating.
    var speed: Double = 0.55

    var body: some View {
        if animating {
            TimelineView(.animation) { context in
                MarkShape(phase: context.date.timeIntervalSinceReferenceDate * speed, size: size, color: color)
            }
        } else {
            MarkShape(phase: nil, size: size, color: color)
        }
    }
}

private struct MarkShape: View {
    /// nil draws the resting logo.
    let phase: Double?
    let size: CGFloat
    let color: Color

    var body: some View {
        let stroke = size * 0.15
        let dot = size * 0.21
        let radius = (size - stroke) / 2
        let geometry = arc(phase)
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            var ring = Path()
            ring.addArc(center: center, radius: radius,
                        startAngle: .radians(-geometry.tail * 2 * .pi), endAngle: .radians(-geometry.head * 2 * .pi),
                        clockwise: true)
            context.stroke(ring, with: .color(color), style: StrokeStyle(lineWidth: stroke, lineCap: .round))

            // The dot rides in the gap, ahead of the head.
            let angle = -geometry.dot * 2 * .pi
            let orbit = radius * 0.98
            let position = CGPoint(x: center.x + orbit * cos(angle), y: center.y + orbit * sin(angle))
            context.fill(Path(ellipseIn: CGRect(x: position.x - dot / 2, y: position.y - dot / 2, width: dot, height: dot)),
                         with: .color(color))
        }
        .frame(width: size, height: size)
    }

    /// Tail, head and dot positions in turns, counter-clockwise from 3 o'clock; the ring runs from tail to head.
    private func arc(_ phase: Double?) -> (tail: Double, head: Double, dot: Double) {
        guard let phase else {
            // Resting logo: dot at about 1–2 o'clock, ring open around it.
            return (tail: 0.264, head: 0.958, dot: 0.11)
        }
        let dot = phase.truncatingRemainder(dividingBy: 1)
        // The body length breathes between a short tail and almost a full ring.
        let length = 0.55 + 0.2 * sin(phase * 2 * .pi * 0.5)
        let gap = 0.15
        let head = dot - gap
        return (tail: head - length, head: head, dot: dot)
    }
}

extension HaluMark {
    /// Static template image for the menu bar.
    @MainActor
    static func menuBarImage(size: CGFloat = 17) -> NSImage {
        let renderer = ImageRenderer(content: HaluMark(size: size, color: .black))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "moon.stars", accessibilityDescription: "Halu")!
        image.isTemplate = true
        return image
    }
}

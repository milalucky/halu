import SwiftUI

/// Notch silhouette: concave flares at the top corners that melt into the bezel,
/// rounded corners at the bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 4)
        let bottom = max(0, min(bottomRadius, rect.height - top, (rect.width - top * 2) / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                          control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// One half of the notch's visible edge, from the middle of the bottom up to the top of one side,
/// inset so a stroke sits fully inside. Two halves trimmed together make a line that drains toward
/// the bottom centre as time runs out.
struct NotchEdge: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var leading: Bool
    var inset: CGFloat = 1.5

    func path(in full: CGRect) -> Path {
        let rect = full.insetBy(dx: inset, dy: 0).divided(atDistance: inset, from: .maxYEdge).remainder
        let top = min(topRadius, rect.width / 4)
        let bottom = max(0, min(bottomRadius, rect.height - top, (rect.width - top * 2) / 2))
        let side = leading ? rect.minX + top : rect.maxX - top
        let corner = leading ? side + bottom : side - bottom
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: corner, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: side, y: rect.maxY - bottom), control: CGPoint(x: side, y: rect.maxY))
        path.addLine(to: CGPoint(x: side, y: rect.minY))
        return path
    }
}

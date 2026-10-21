import SwiftUI

extension View {
    /// Liquid Glass on macOS 26 and later (optionally tinted, and reacting to the pointer), a soft card
    /// fill before that.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let base: Glass = tint.map { Glass.regular.tint($0.opacity(0.35)) } ?? .regular
            self.glassEffect(interactive ? base.interactive() : base, in: shape)
        } else {
            self.background(shape.fill(tint.map { $0.opacity(0.14) } ?? Theme.card))
        }
    }
}

/// A little burst of dots, for a task checked off.
struct Burst: View {
    let tint: Color
    @State private var fired = false

    var body: some View {
        ZStack {
            ForEach(0..<10, id: \.self) { index in
                let angle = Double(index) / 10 * 2 * .pi
                Circle()
                    .fill(index.isMultiple(of: 3) ? Theme.orange : index.isMultiple(of: 2) ? Theme.green : tint)
                    .frame(width: 4, height: 4)
                    .offset(x: fired ? cos(angle) * 18 : 0, y: fired ? sin(angle) * 18 : 0)
                    .scaleEffect(fired ? 0.3 : 1)
                    .opacity(fired ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeOut(duration: 0.55)) { fired = true } }
    }
}

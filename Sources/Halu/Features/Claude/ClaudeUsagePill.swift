import HaluCore
import SwiftUI

/// How much of the Claude plan is used: the 5-hour window (and the week in the tooltip), as Claude
/// Code's status line reports it. Hidden until there's a reading, or when it's stale.
struct ClaudeUsagePill: View {
    @ObservedObject var requests: ClaudeRequests

    var body: some View {
        if let usage = requests.usage, Date().timeIntervalSince(usage.updatedAt) < 6 * 3600,
           let shown = live(usage.fiveHour) ?? live(usage.sevenDay) {
            let tint = shown.usedPercentage >= 85 ? Theme.red : shown.usedPercentage >= 60 ? Theme.orange : Theme.secondary
            HStack(spacing: 4) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 1.6)
                    Circle()
                        .trim(from: 0, to: min(1, shown.usedPercentage / 100))
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 10, height: 10)
                Text("\(Int(shown.usedPercentage))%")
                    .font(Theme.caption(11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 7)
            .frame(height: 20)
            .glass(Capsule())
            .fixedSize()
            .help(help(usage))
        }
    }

    /// A window whose reset time hasn't passed.
    private func live(_ window: ClaudeUsage.Window?) -> ClaudeUsage.Window? {
        guard let window else { return nil }
        if let resets = window.resetsAt, resets < Date() { return nil }
        return window
    }

    private func help(_ usage: ClaudeUsage) -> String {
        func line(_ name: String, _ window: ClaudeUsage.Window?) -> String? {
            guard let window = live(window) else { return nil }
            let reset = window.resetsAt.map { " · resets \(Fmt.until($0))" } ?? ""
            return "\(name): \(Int(window.usedPercentage))% used\(reset)"
        }
        return (["Claude plan"] + [line("5 hours", usage.fiveHour), line("Week", usage.sevenDay)].compactMap { $0 }).joined(separator: "\n")
    }
}

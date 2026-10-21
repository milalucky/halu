import SwiftUI

/// The week in numbers: this week so far, or the last one.
struct RecapView: View {
    let tasks: [TaskItem]
    let onBack: () -> Void
    @State private var lastWeek = Calendar.current.component(.weekday, from: .now) == 2
    @State private var appeared = false

    private var recap: WeekRecap {
        let thisStart = WeekRecap.weekStart(.now)
        let start = lastWeek ? Calendar.current.date(byAdding: .day, value: -7, to: thisStart)! : thisStart
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
        return WeekRecap.make(for: start..<end, tasks: tasks)
    }

    var body: some View {
        let recap = recap
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                IconButton(icon: "chevron.left", help: "Back") { withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { onBack() } }
                SectionHeader(title: lastWeek ? "Last week" : "This week", detail: range(recap.range))
                Spacer()
                Picker("", selection: $lastWeek) {
                    Text("This week").tag(false)
                    Text("Last week").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                StatCard(icon: "checkmark.circle.fill", tint: Theme.accent, value: "\(recap.tasksDone)", label: "tasks done", delay: 0, appeared: appeared)
                StatCard(icon: "flame.fill", tint: Theme.orange, value: hours(recap.focusMinutes / 60), label: "in focus", delay: 0.05, appeared: appeared)
                StatCard(icon: "video.fill", tint: Theme.blue, value: "\(recap.meetings)", label: "meetings · \(hours(recap.meetingHours))", delay: 0.1, appeared: appeared)
                StatCard(icon: "sparkle", tint: Theme.orange, value: "\(recap.claudeSessions)", label: "Claude sessions", delay: 0.15, appeared: appeared)
                StatCard(icon: "gearshape.2.fill", tint: Theme.green, value: "\(recap.pipelines)", label: "pipelines", delay: 0.2, appeared: appeared)
                StatCard(icon: "tag.fill", tint: Theme.accent, value: recap.topTags.first?.0 ?? "—", label: recap.topTags.first.map { "top tag · \($0.1)" } ?? "no tags yet", delay: 0.25, appeared: appeared)
            }
            DayBars(counts: recap.tasksPerDay, appeared: appeared)
        }
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { appeared = true } }
    }

    private func hours(_ value: Double) -> String {
        value < 1 ? "\(Int((value * 60).rounded()))m" : String(format: value < 10 ? "%.1fh" : "%.0fh", value)
    }

    private func range(_ range: Range<Date>) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return "\(formatter.string(from: range.lowerBound)) – \(formatter.string(from: range.upperBound.addingTimeInterval(-1)))"
    }
}

private struct StatCard: View {
    let icon: String
    let tint: Color
    let value: String
    let label: String
    let delay: Double
    let appeared: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Theme.primary).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(Theme.caption(10.5, weight: .medium)).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glass(RoundedRectangle(cornerRadius: 12, style: .continuous), tint: tint.opacity(0.4))
        .scaleEffect(appeared ? 1 : 0.85)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(delay), value: appeared)
    }
}

/// Tasks done per weekday, as bars that grow in.
private struct DayBars: View {
    let counts: [Int]
    let appeared: Bool

    var body: some View {
        let top = max(1, counts.max() ?? 1)
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(0..<7, id: \.self) { day in
                VStack(spacing: 4) {
                    Text(counts[day] > 0 ? "\(counts[day])" : "").font(Theme.caption(9.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.accent.opacity(0.5), Theme.accent], startPoint: .bottom, endPoint: .top))
                        .frame(height: appeared ? max(3, 46 * CGFloat(counts[day]) / CGFloat(top)) : 3)
                        .animation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.3 + Double(day) * 0.04), value: appeared)
                    Text(["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"][day]).font(Theme.caption(9.5, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 76)
        .padding(.horizontal, 4)
    }
}

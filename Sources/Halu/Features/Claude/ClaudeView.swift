import HaluCore
import SwiftUI

struct ClaudeView: View {
    @ObservedObject var store: ClaudeStore

    var body: some View {
        if !store.hooksInstalled {
            EmptyState(icon: "sparkle", title: "Connect Claude Code",
                       subtitle: store.installError ?? "Halu adds a small hook to ~/.claude/settings.json so your sessions can report what they're doing. A backup is saved next to it.",
                       action: ("Connect", store.installHooks))
        } else {
            let active = store.rows.filter { $0.phase != .done }
            let done = store.rows.filter { $0.phase == .done }
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Sessions", detail: summary)
                if store.rows.isEmpty {
                    EmptyState(icon: "moon.zzz", title: "No sessions yet",
                               subtitle: "Sessions show up here as soon as Claude starts working.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(active) { row in
                                SessionRow(row: row, onOpen: store.openClaude,
                                           onToggleDone: { withAnimation { store.markDone(row.session) } })
                            }
                            if !done.isEmpty {
                                Text("DONE")
                                    .font(Theme.caption(10, weight: .semibold))
                                    .tracking(0.6)
                                    .foregroundStyle(Theme.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                ForEach(done) { row in
                                    SessionRow(row: row, onOpen: store.openClaude,
                                               onToggleDone: { withAnimation { store.reopen(row.session) } })
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
        }
    }

    private var summary: String? {
        let waiting = store.rows.filter { $0.phase == .needsYou }.count
        let working = store.rows.filter { $0.phase == .working }.count
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if working > 0 { parts.append("\(working) working") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct SessionRow: View {
    let row: ClaudeRow
    let onOpen: () -> Void
    let onToggleDone: () -> Void
    @State private var hovering = false

    private var session: ClaudeSession { row.session }

    private var tint: Color {
        switch row.phase {
        case .needsYou: Theme.orange
        case .working: Theme.accent
        case .yourTurn: Theme.blue
        case .quiet: Theme.tertiary
        case .done: Theme.green
        }
    }

    private var statusText: String {
        switch row.phase {
        case .needsYou: session.message ?? "Waiting for you"
        case .working: session.currentStep ?? "Working"
        case .yourTurn: session.status == .idle ? "Ready" : "Your turn"
        case .quiet: "No activity for a while"
        case .done: "Done"
        }
    }

    private var progress: Double? {
        let total = session.steps.count
        let fraction = total > 0 ? Double(session.completedSteps) / Double(total) : 0
        switch row.phase {
        case .working: return total > 0 ? fraction : nil
        case .done: return 1
        default: return fraction
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                if row.phase == .working {
                    HaluMark(size: 14, color: tint, animating: true)
                } else {
                    StatusDot(tint: tint, pulsing: false)
                }
                Text(session.displayTitle)
                    .font(Theme.body(13, weight: .medium))
                    .foregroundStyle(row.phase == .done ? Theme.secondary : Theme.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if hovering {
                    IconButton(icon: row.phase == .done ? "arrow.uturn.backward" : "checkmark",
                               help: row.phase == .done ? "Move back to active" : "Mark as done",
                               size: 10, action: onToggleDone)
                } else {
                    Text(Fmt.ago(session.updatedAt))
                        .font(Theme.caption(11, weight: .regular))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            ProgressLine(value: progress, tint: tint)
            HStack(spacing: 6) {
                Text(session.project).foregroundStyle(Theme.secondary)
                Text("·").foregroundStyle(Theme.tertiary)
                Text(statusText)
                    .foregroundStyle(row.phase == .needsYou ? Theme.orange : (row.phase == .yourTurn ? Theme.blue : Theme.tertiary))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !session.steps.isEmpty {
                    Text("\(session.completedSteps)/\(session.steps.count)")
                        .foregroundStyle(Theme.tertiary)
                        .monospacedDigit()
                }
            }
            .font(Theme.caption(11, weight: .regular))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(row.phase == .needsYou ? Theme.orange.opacity(0.08) : (hovering ? Theme.cardHover : Theme.card))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(row.phase == .needsYou ? Theme.orange.opacity(0.35) : .clear, lineWidth: 1)
        )
        .opacity(row.phase == .done ? 0.7 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
    }
}

private struct StatusDot: View {
    let tint: Color
    let pulsing: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(tint.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1 : 0.4)
                    .opacity(pulse ? 0 : 1)
            }
            Circle().fill(tint).frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

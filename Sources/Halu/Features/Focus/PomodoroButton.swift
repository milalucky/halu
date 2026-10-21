import SwiftUI

/// Focus timer in the header: a click starts, pauses or resumes; the ring empties as the round runs.
/// Right-click for the length, a break, or stop.
struct PomodoroButton: View {
    @ObservedObject var pomodoro: PomodoroTimer
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let tint = pomodoro.phase == .focus ? Theme.orange : Theme.green
            Button(action: pomodoro.toggle) {
                ZStack {
                    if pomodoro.isOn {
                        Circle().stroke(Color.white.opacity(0.12), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: pomodoro.remaining(at: context.date))
                            .stroke(pomodoro.isRunning ? tint : Theme.tertiary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: pomodoro.isRunning ? (pomodoro.phase == .focus ? "flame.fill" : "cup.and.saucer.fill") : "pause.fill")
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundStyle(pomodoro.isRunning ? tint : Theme.secondary)
                    } else {
                        Image(systemName: "timer")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(hovering ? Theme.secondary : Theme.tertiary)
                    }
                }
                .frame(width: 15, height: 15)
                .headerButton(active: false, hovering: hovering)
            }
            .buttonStyle(.plain)
            .help(help(at: context.date))
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Focus 25 minutes") { pomodoro.startFocus(minutes: 25) }
            Button("Focus 50 minutes") { pomodoro.startFocus(minutes: 50) }
            Button("Focus 15 minutes") { pomodoro.startFocus(minutes: 15) }
            Button("Break 5 minutes") { pomodoro.startRest() }
            if pomodoro.isOn {
                Divider()
                Button("Stop") { pomodoro.stop() }
            }
        }
    }

    private func help(at now: Date) -> String {
        guard pomodoro.isOn else { return "Focus timer · \(pomodoro.focusMinutes) min · right-click for more" }
        let left = Int(pomodoro.left(at: now).rounded(.up))
        let what = pomodoro.phase == .focus ? "Focus" : "Break"
        return "\(what) · \(left / 60):\(String(format: "%02d", left % 60)) left · click to \(pomodoro.isRunning ? "pause" : "resume")"
    }
}

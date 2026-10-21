import SwiftUI

/// Something happening in time that the collapsed notch shows live, like Dynamic Island: a meeting
/// counting down (and started, until you join) or a focus timer.
enum LiveActivity: Equatable {
    case meeting(Meeting)
    case pomodoro
}

/// Works out once a second what the notch should show live.
@MainActor
final class LiveCenter: ObservableObject {
    @Published private(set) var activity: LiveActivity?

    private let calendar: CalendarStore
    private let pomodoro: PomodoroTimer
    private var timer: Timer?

    init(calendar: CalendarStore, pomodoro: PomodoroTimer) {
        self.calendar = calendar
        self.pomodoro = pomodoro
    }

    func start() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        update()
    }

    func update() {
        let now = Date()
        let meeting = calendar.countdown(at: now)
        var next: LiveActivity?
        // A meeting within 5 minutes (or started) wins over the timer; further off, the timer shows.
        if let meeting, meeting.start.timeIntervalSince(now) <= 5 * 60 || !pomodoro.isOn {
            next = .meeting(meeting)
        } else if pomodoro.isOn {
            next = .pomodoro
        }
        if next != activity { activity = next }
    }
}

/// The collapsed notch while something is live: what it is on the left, time on the right, and a
/// glowing line running round the notch that shrinks as time runs out.
struct LiveView: View {
    let activity: LiveActivity
    let attention: Bool
    @ObservedObject var pomodoro: PomodoroTimer
    let shape: NotchShape
    let calendar: CalendarStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let state = state(at: now)
            ZStack {
                // The line drains from both top ends toward the bottom centre.
                ForEach([true, false], id: \.self) { leading in
                    NotchEdge(topRadius: shape.topRadius, bottomRadius: shape.bottomRadius, leading: leading)
                        .trim(from: 0, to: max(0.001, state.remaining))
                        .stroke(state.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .shadow(color: state.tint.opacity(state.urgent ? 0.8 : 0.45), radius: state.urgent ? 5 : 3)
                }
                .animation(.linear(duration: 1), value: state.remaining)
                HStack(spacing: 0) {
                    HStack(spacing: 5) {
                        Image(systemName: state.icon)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(state.tint)
                            .symbolEffect(.pulse, options: .repeating, isActive: state.urgent)
                        if attention { Circle().fill(Theme.orange).frame(width: 5, height: 5) }
                    }
                    .frame(width: Layout.liveWing)
                    Spacer(minLength: 0)
                    Text(state.label)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(state.urgent ? state.tint : Theme.primary)
                        .contentTransition(.numericText(countsDown: true))
                        .frame(width: Layout.liveWing)
                }
                .padding(.horizontal, Layout.flare)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { tap() }
        }
    }

    private struct State {
        var icon: String
        var label: String
        var tint: Color
        var remaining: Double
        var urgent: Bool
    }

    private func state(at now: Date) -> State {
        switch activity {
        case .meeting(let meeting):
            let lead = meeting.start.timeIntervalSince(now)
            if lead <= 0 {
                return State(icon: "video.fill", label: "+\(Int(-lead / 60))m", tint: Theme.red, remaining: 1, urgent: true)
            }
            let label = lead < 60 ? "0:\(String(format: "%02d", Int(lead)))" : "\(Int((lead / 60).rounded(.up)))m"
            return State(icon: "video.fill", label: label, tint: lead <= 60 ? Theme.orange : Theme.accent,
                         remaining: min(1, lead / (15 * 60)), urgent: lead <= 60)
        case .pomodoro:
            let left = Int(pomodoro.left(at: now).rounded(.up))
            let label = String(format: "%d:%02d", left / 60, left % 60)
            let tint = pomodoro.phase == .focus ? Theme.orange : Theme.green
            return State(icon: pomodoro.isRunning ? (pomodoro.phase == .focus ? "flame.fill" : "cup.and.saucer.fill") : "pause.fill",
                         label: label, tint: pomodoro.isRunning ? tint : Theme.tertiary,
                         remaining: pomodoro.remaining(at: now), urgent: false)
        }
    }

    /// A meeting: join it. The timer: pause or resume.
    private func tap() {
        switch activity {
        case .meeting(let meeting): calendar.join(meeting)
        case .pomodoro: pomodoro.toggle()
        }
    }
}

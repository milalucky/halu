import SwiftUI

/// Something happening in time that the collapsed notch shows live, like Dynamic Island: a meeting
/// counting down (and started, until you join), a focus timer, or lunch.
enum LiveActivity: Equatable {
    case meeting(Meeting)
    case pomodoro
    case lunch(Meeting)
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
        // Lunch is the quietest: anything else on the clock comes first.
        if let meeting, meeting.start.timeIntervalSince(now) <= 5 * 60 || !pomodoro.isOn {
            next = .meeting(meeting)
        } else if pomodoro.isOn {
            next = .pomodoro
        } else if let lunch = calendar.lunch(at: now) {
            next = .lunch(lunch)
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
                if case .lunch = activity {
                    LunchSnake(shape: shape)
                } else {
                    timeLine(state)
                }
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

    /// The line drains from both top ends toward the bottom centre.
    private func timeLine(_ state: State) -> some View {
        ForEach([true, false], id: \.self) { leading in
            NotchEdge(topRadius: shape.topRadius, bottomRadius: shape.bottomRadius, leading: leading)
                .trim(from: 0, to: max(0.001, state.remaining))
                .stroke(state.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .shadow(color: state.tint.opacity(state.urgent ? 0.8 : 0.45), radius: state.urgent ? 5 : 3)
        }
        .animation(.linear(duration: 1), value: state.remaining)
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
        case .lunch(let lunch):
            let minutes = Int((max(0, lunch.end.timeIntervalSince(now)) / 60).rounded(.up))
            let label = minutes >= 60 ? "\(minutes / 60)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")" : "\(minutes)m"
            return State(icon: "fork.knife", label: label, tint: Theme.orange, remaining: 1, urgent: false)
        }
    }

    /// A meeting: join it. The timer: pause or resume. Lunch: back early, the snake goes.
    private func tap() {
        switch activity {
        case .meeting(let meeting): calendar.join(meeting)
        case .pomodoro: pomodoro.toggle()
        case .lunch(let lunch): calendar.dismissCountdown(lunch)
        }
    }
}

/// Lunch on the notch: a snake runs to and fro along the notch edge, eating one bite per run and
/// growing, until lunch is over. Worked out from the clock alone, so it keeps no state.
private struct LunchSnake: View {
    let shape: NotchShape
    /// Seconds for one run from one end of the edge to the other.
    private let lap: Double = 7
    private let segments = 10

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            Canvas { ctx, size in
                let path = NotchOutline(topRadius: shape.topRadius, bottomRadius: shape.bottomRadius)
                    .path(in: CGRect(origin: .zero, size: size))
                let time = context.date.timeIntervalSinceReferenceDate
                let t = time / lap
                let run = Int(t.rounded(.down))
                let progress = t - t.rounded(.down)
                let forward = run % 2 == 0
                let head = forward ? progress : 1 - progress
                // One bite per run, somewhere away from the ends; after eight it starts small again.
                let food = 0.12 + 0.76 * Self.noise(run)
                let eaten = forward ? head >= food : head <= food
                let length = 0.05 + 0.012 * Double(run % 8 + (eaten ? 1 : 0))
                let tail = forward ? head - length : head + length

                ctx.drawLayer { layer in
                    layer.addFilter(.shadow(color: Theme.green.opacity(0.7), radius: 3))
                    // The body fades toward the tail.
                    for i in 0..<segments {
                        let a = tail + (head - tail) * Double(i) / Double(segments)
                        let b = tail + (head - tail) * Double(i + 1) / Double(segments)
                        let from = max(0, min(a, b)), to = min(1, max(a, b))
                        guard to > from else { continue }
                        layer.stroke(path.trimmedPath(from: from, to: to),
                                     with: .color(Theme.green.opacity(0.25 + 0.75 * Double(i + 1) / Double(segments))),
                                     style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    }
                    let point = Self.point(on: path, at: head)
                    layer.fill(Path(ellipseIn: CGRect(x: point.x - 2.25, y: point.y - 2.25, width: 4.5, height: 4.5)),
                               with: .color(Theme.green))
                }
                if !eaten {
                    let point = Self.point(on: path, at: food)
                    let r = 2 * (1 + 0.25 * sin(time * 5))
                    ctx.drawLayer { layer in
                        layer.addFilter(.shadow(color: Theme.orange.opacity(0.8), radius: 3))
                        layer.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
                                   with: .color(Theme.orange))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func point(on path: Path, at fraction: Double) -> CGPoint {
        path.trimmedPath(from: 0, to: max(0.0001, min(1, fraction))).currentPoint ?? .zero
    }

    /// A steady pseudo-random 0..<1 for each run.
    private static func noise(_ n: Int) -> Double {
        let x = sin(Double(n) * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }
}

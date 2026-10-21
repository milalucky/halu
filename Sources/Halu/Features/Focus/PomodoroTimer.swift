import Foundation

/// Focus and break timer. A focus round ends with a break that starts on its own; the break ends the
/// cycle. Survives Halu restarting, since only the end time is kept.
@MainActor
final class PomodoroTimer: ObservableObject {
    enum Phase: String { case focus, rest }

    @Published private(set) var phase: Phase = .focus
    /// When the running round ends.
    @Published private(set) var endsAt: Date?
    /// Time left in a paused round.
    @Published private(set) var pausedLeft: TimeInterval?
    @Published private(set) var total: TimeInterval = 25 * 60

    var focusMinutes = UserDefaults.standard.object(forKey: "pomodoro.focus") as? Int ?? 25 {
        didSet { UserDefaults.standard.set(focusMinutes, forKey: "pomodoro.focus") }
    }
    let restMinutes = 5

    /// Called when a round ends.
    var onFinish: (Phase) -> Void = { _ in }

    private var timer: Timer?

    var isRunning: Bool { endsAt != nil }
    var isOn: Bool { endsAt != nil || pausedLeft != nil }

    init() {
        let defaults = UserDefaults.standard
        if let end = defaults.object(forKey: "pomodoro.endsAt") as? Date, end > Date() {
            endsAt = end
            phase = Phase(rawValue: defaults.string(forKey: "pomodoro.phase") ?? "") ?? .focus
            total = defaults.double(forKey: "pomodoro.total")
        }
        tick()
    }

    func left(at now: Date = .now) -> TimeInterval {
        if let endsAt { return max(0, endsAt.timeIntervalSince(now)) }
        return pausedLeft ?? 0
    }

    /// Share of the round still left, 1 → 0.
    func remaining(at now: Date = .now) -> Double {
        total > 0 ? left(at: now) / total : 0
    }

    func startFocus(minutes: Int? = nil) {
        if let minutes { focusMinutes = minutes }
        begin(.focus, length: TimeInterval(focusMinutes * 60))
    }

    func startRest() { begin(.rest, length: TimeInterval(restMinutes * 60)) }

    /// Header button: start, pause or resume.
    func toggle() {
        if let endsAt {
            pausedLeft = max(0, endsAt.timeIntervalSinceNow)
            self.endsAt = nil
            save()
        } else if let pausedLeft {
            endsAt = Date().addingTimeInterval(pausedLeft)
            self.pausedLeft = nil
            save()
        } else {
            startFocus()
        }
    }

    func stop() {
        endsAt = nil
        pausedLeft = nil
        phase = .focus
        save()
    }

    private func begin(_ phase: Phase, length: TimeInterval) {
        self.phase = phase
        total = length
        pausedLeft = nil
        endsAt = Date().addingTimeInterval(length)
        save()
        tick()
    }

    private func tick() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        guard let endsAt, endsAt <= Date() else { return }
        let finished = phase
        self.endsAt = nil
        onFinish(finished)
        if finished == .focus { startRest() } else { stop() }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(endsAt, forKey: "pomodoro.endsAt")
        defaults.set(phase.rawValue, forKey: "pomodoro.phase")
        defaults.set(total, forKey: "pomodoro.total")
    }
}

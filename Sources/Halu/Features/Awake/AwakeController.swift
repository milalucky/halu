import Foundation

/// Keeps the Mac and its display awake by running `caffeinate`, tied to Halu's own process so it
/// never outlives the app. The choice is remembered, so it comes back on after Halu restarts.
@MainActor
final class AwakeController: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var until: Date?

    private var process: Process?

    /// Turns back on after a relaunch if it was on (and its time limit hasn't passed).
    func restore() {
        guard UserDefaults.standard.bool(forKey: "awake.on") else { return }
        if let until = UserDefaults.standard.object(forKey: "awake.until") as? Date {
            let left = until.timeIntervalSinceNow
            if left > 60 { start(for: left) } else { remember(nil) }
        } else {
            start()
        }
    }

    func toggle() {
        isOn ? stop() : start()
    }

    func start(for duration: TimeInterval? = nil) {
        stop()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // d: display, i: idle sleep, m: disk, s: system sleep on power.
        var arguments = ["-dims", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
        if let duration { arguments += ["-t", "\(Int(duration))"] }
        process.arguments = arguments
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { self?.didExit(finished) }
        }
        do {
            try process.run()
        } catch {
            NSLog("Halu: caffeinate failed: \(error.localizedDescription)")
            return
        }
        self.process = process
        isOn = true
        until = duration.map { Date().addingTimeInterval($0) }
        remember(until)
    }

    func stop() {
        guard let process else { return }
        self.process = nil
        process.terminate()
        isOn = false
        until = nil
        UserDefaults.standard.set(false, forKey: "awake.on")
    }

    private func remember(_ until: Date?) {
        UserDefaults.standard.set(until != nil || isOn, forKey: "awake.on")
        UserDefaults.standard.set(until, forKey: "awake.until")
    }

    private func didExit(_ finished: Process) {
        guard finished === process else { return }
        process = nil
        isOn = false
        until = nil
        // The time limit ran out.
        UserDefaults.standard.set(false, forKey: "awake.on")
    }
}

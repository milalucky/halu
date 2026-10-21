import Foundation

/// Keeps the Mac from sleeping by running `caffeinate`, tied to Halu's own process so it
/// never outlives the app. The display may still sleep; the system and running work don't.
@MainActor
final class AwakeController: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var until: Date?

    private var process: Process?

    func toggle() {
        isOn ? stop() : start()
    }

    func start(for duration: TimeInterval? = nil) {
        stop()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        var arguments = ["-ims", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
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
    }

    func stop() {
        guard let process else { return }
        self.process = nil
        process.terminate()
        isOn = false
        until = nil
    }

    private func didExit(_ finished: Process) {
        guard finished === process else { return }
        process = nil
        isOn = false
        until = nil
    }
}

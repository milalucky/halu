import AppKit
import HaluCore

extension ClaudeSession {
    var displayTitle: String { title.isEmpty ? project : title }
}

/// How a session reads to the user. A finished turn is not a finished session: it stays
/// "Your turn" until it is marked done or has been quiet for a day.
enum SessionPhase: Int, Comparable {
    case needsYou, working, yourTurn, quiet, done

    static func < (lhs: SessionPhase, rhs: SessionPhase) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct ClaudeRow: Identifiable, Equatable {
    var session: ClaudeSession
    var phase: SessionPhase
    var id: String { session.id }
}

/// Watches the snapshots `halu-hook` writes and reports status changes.
@MainActor
final class ClaudeStore: ObservableObject {
    @Published private(set) var rows: [ClaudeRow] = []
    @Published private(set) var hooksInstalled = HookInstaller.isInstalled
    @Published var installError: String?

    /// Fired when a session starts waiting for the user, or ends a turn that took a while.
    var onTransition: (ClaudeSession) -> Void = { _ in }

    /// Quiet this long after its last activity, a session counts as done.
    private let doneAfter: TimeInterval = 24 * 3600
    /// A "working" session with no hook events for this long was most likely closed mid-turn.
    private let quietAfter: TimeInterval = 30 * 60

    private var known: [String: ClaudeStatus] = [:]
    private var loadedOnce = false
    /// Sessions marked done by hand, with the activity time they were marked at; new activity reopens them.
    private var closed: [String: Date] = UserDefaults.standard.dictionary(forKey: "claude.closed") as? [String: Date] ?? [:]
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?

    var attention: [ClaudeSession] { rows.filter { $0.phase == .needsYou }.map(\.session) }

    func start() {
        let directory = HaluPaths.ensure(HaluPaths.claudeSessions)
        if hooksInstalled { try? HookInstaller.refreshHookBinary() }
        reload()

        let descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.reload() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        }
        // Safety net for missed file events and for ageing sessions.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func installHooks() {
        do {
            try HookInstaller.install()
            hooksInstalled = true
            installError = nil
        } catch {
            installError = error.localizedDescription
        }
    }

    func markDone(_ session: ClaudeSession) {
        closed[session.id] = session.updatedAt
        saveClosed()
        reload()
    }

    func reopen(_ session: ClaudeSession) {
        closed[session.id] = nil
        saveClosed()
        reload()
    }

    func openClaude() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func phase(of session: ClaudeSession, now: Date) -> SessionPhase {
        if let closedAt = closed[session.id], session.updatedAt <= closedAt { return .done }
        let quiet = now.timeIntervalSince(session.updatedAt)
        switch session.status {
        case .needsInput: return .needsYou
        case .working: return quiet > quietAfter ? .quiet : .working
        case .done, .idle: return quiet > doneAfter ? .done : .yourTurn
        }
    }

    func reload() {
        let directory = HaluPaths.claudeSessions
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = HaluJSON.decoder()
        let now = Date()
        var loaded: [ClaudeSession] = []

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(ClaudeSession.self, from: data) else { continue }
            if now.timeIntervalSince(session.updatedAt) > 7 * 86400 {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            loaded.append(session)
        }

        for session in loaded {
            let previous = known[session.id]
            known[session.id] = session.status
            guard loadedOnce, previous != session.status else { continue }
            if session.status == .needsInput {
                onTransition(session)
            } else if session.status == .done, previous == .working || previous == .needsInput,
                      let started = session.turnStartedAt, session.updatedAt.timeIntervalSince(started) > 20 {
                onTransition(session)
            }
        }
        loadedOnce = true

        let all: [ClaudeRow] = loaded.map { ClaudeRow(session: $0, phase: phase(of: $0, now: now)) }
        // Done sessions linger for two days in the bottom section, then drop off.
        let shown: [ClaudeRow] = all.filter { row in
            row.phase != .done || now.timeIntervalSince(row.session.updatedAt) < 2 * 86400
        }
        let fresh: [ClaudeRow] = shown.sorted { (lhs: ClaudeRow, rhs: ClaudeRow) -> Bool in
            if lhs.phase != rhs.phase { return lhs.phase < rhs.phase }
            return lhs.session.updatedAt > rhs.session.updatedAt
        }
        if fresh != rows { rows = fresh }
    }

    private func saveClosed() {
        let ids = Set(known.keys)
        closed = closed.filter { ids.contains($0.key) }
        UserDefaults.standard.set(closed, forKey: "claude.closed")
    }
}

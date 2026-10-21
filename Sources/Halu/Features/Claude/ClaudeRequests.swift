import AppKit
import HaluCore

/// Questions Claude Code is waiting on (from `halu-hook`), answered from the notch. Also keeps the
/// heartbeat that tells the hook Halu is there to answer, and reads plan usage from the status line.
@MainActor
final class ClaudeRequests: ObservableObject {
    @Published private(set) var pending: [ClaudeRequest] = []
    @Published private(set) var usage: ClaudeUsage?

    private var timer: Timer?
    private var beats = 0

    var current: ClaudeRequest? { pending.first }

    func start() {
        HaluPaths.ensure(HaluPaths.claudeRequests)
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func answer(_ request: ClaudeRequest, _ decision: ClaudeAnswer.Decision, answers: [String: String]? = nil) {
        let reply = ClaudeAnswer(decision: decision, answers: answers)
        if let data = try? HaluJSON.encoder().encode(reply) {
            try? data.write(to: HaluPaths.answerFile(for: request.id), options: .atomic)
        }
        pending.removeAll { $0.id == request.id }
    }

    private func tick() {
        beats += 1
        if beats % 10 == 1 { beat() }
        if beats % 25 == 1 { readUsage() }
        readRequests()
    }

    private func beat() {
        let url = HaluPaths.heartbeat
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
    }

    private func readRequests() {
        let files = (try? FileManager.default.contentsOfDirectory(at: HaluPaths.claudeRequests, includingPropertiesForKeys: nil)) ?? []
        let found = files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".answer.json") }
            .compactMap { try? HaluJSON.decoder().decode(ClaudeRequest.self, from: Data(contentsOf: $0)) }
            // The hook gives up after 110 s; anything older is left over.
            .filter { Date().timeIntervalSince($0.createdAt) < 115 }
            .sorted { $0.createdAt < $1.createdAt }
        if found != pending {
            if found.contains(where: { request in !pending.contains { $0.id == request.id } }) {
                Services.shared.notices.dismissClaude()
                NSSound(named: NSSound.Name("Tink"))?.play()
            }
            pending = found
        }
    }

    private func readUsage() {
        let fresh = (try? Data(contentsOf: HaluPaths.claudeUsage)).flatMap { try? HaluJSON.decoder().decode(ClaudeUsage.self, from: $0) }
        if fresh != usage { usage = fresh }
    }
}

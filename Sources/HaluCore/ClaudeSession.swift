import Foundation

/// Lifecycle of a Claude Code session as reported by its hooks.
public enum ClaudeStatus: String, Codable, Sendable {
    case idle
    case working
    case needsInput
    case done
}

public struct ClaudeStep: Codable, Sendable, Equatable {
    public var content: String
    /// `pending`, `in_progress` or `completed`.
    public var status: String

    public init(content: String, status: String) {
        self.content = content
        self.status = status
    }
}

/// Snapshot of one session, written by `halu-hook` and read by the app.
public struct ClaudeSession: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var cwd: String
    public var title: String
    public var status: ClaudeStatus
    public var message: String?
    public var steps: [ClaudeStep]
    public var startedAt: Date
    public var updatedAt: Date
    public var turnStartedAt: Date?

    public init(id: String, cwd: String, now: Date) {
        self.id = id
        self.cwd = cwd
        self.title = ""
        self.status = .idle
        self.message = nil
        self.steps = []
        self.startedAt = now
        self.updatedAt = now
        self.turnStartedAt = nil
    }

    public var completedSteps: Int { steps.filter { $0.status == "completed" }.count }
    public var currentStep: String? { steps.first { $0.status == "in_progress" }?.content }
    public var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Claude" : name
    }
}

public enum HaluPaths {
    public static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Halu", isDirectory: true)
    }

    public static var claudeSessions: URL { support.appendingPathComponent("claude", isDirectory: true) }

    @discardableResult
    public static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

public enum HaluJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public extension ClaudeSession {
    /// What a person typed, without the blocks apps wrap around a prompt (`<system-reminder>`,
    /// slash-command markup and the like), on one line.
    static func cleanPrompt(_ text: String) -> String {
        var result = text
        let blocks = #"<(system-reminder|command-name|command-message|command-args|local-command-stdout|local-command-caveat|user-prompt-submit-hook|ide_[a-z_]+)[^>]*>[\s\S]*?</\1>"#
        result = result.replacingOccurrences(of: blocks, with: " ", options: .regularExpression)
        // An unclosed system block runs to the end.
        result = result.replacingOccurrences(of: #"<system-reminder>[\s\S]*$"#, with: " ", options: .regularExpression)
        return result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}

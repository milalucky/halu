import Foundation

/// A question Claude Code is waiting on, handed from `halu-hook` to Halu so it can be answered
/// from the notch: a permission to use a tool, or an AskUserQuestion prompt.
public struct ClaudeRequest: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable { case permission, question }

    public struct Option: Codable, Equatable {
        public var label: String
        public var description: String?

        public init(label: String, description: String?) {
            self.label = label
            self.description = description
        }
    }

    public struct Question: Codable, Equatable {
        public var question: String
        public var header: String?
        public var options: [Option]
        public var multiSelect: Bool?

        public init(question: String, header: String?, options: [Option], multiSelect: Bool?) {
            self.question = question
            self.header = header
            self.options = options
            self.multiSelect = multiSelect
        }
    }

    public var id: String
    public var kind: Kind
    public var sessionID: String
    public var project: String
    public var toolName: String
    /// What the tool would do: a command, a file, an address.
    public var summary: String
    public var questions: [Question]
    /// Claude Code offered "always allow" rules for this request.
    public var canAlwaysAllow: Bool
    public var createdAt: Date

    public init(id: String, kind: Kind, sessionID: String, project: String, toolName: String, summary: String,
                questions: [Question], canAlwaysAllow: Bool, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.sessionID = sessionID
        self.project = project
        self.toolName = toolName
        self.summary = summary
        self.questions = questions
        self.canAlwaysAllow = canAlwaysAllow
        self.createdAt = createdAt
    }
}

/// Halu's reply. `terminal` hands the question back to Claude Code's own prompt.
public struct ClaudeAnswer: Codable, Equatable {
    public enum Decision: String, Codable { case allow, always, deny, terminal }

    public var decision: Decision
    /// Question text → chosen label(s), comma-joined for multi-select.
    public var answers: [String: String]?

    public init(decision: Decision, answers: [String: String]? = nil) {
        self.decision = decision
        self.answers = answers
    }
}

public extension HaluPaths {
    static var claudeRequests: URL { support.appendingPathComponent("claude-requests", isDirectory: true) }
    /// Touched by Halu every few seconds; the hook only waits for an answer while Halu is running.
    static var heartbeat: URL { support.appendingPathComponent("alive") }
    /// Plan usage as the Claude Code status line last reported it.
    static var claudeUsage: URL { support.appendingPathComponent("claude-usage.json") }

    static func answerFile(for id: String) -> URL { claudeRequests.appendingPathComponent("\(id).answer.json") }
    static func requestFile(for id: String) -> URL { claudeRequests.appendingPathComponent("\(id).json") }
}

/// The two plan windows, as the status line reports them.
public struct ClaudeUsage: Codable, Equatable {
    public struct Window: Codable, Equatable {
        public var usedPercentage: Double
        public var resetsAt: Date?
        public init(usedPercentage: Double, resetsAt: Date?) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }
    }

    public var fiveHour: Window?
    public var sevenDay: Window?
    public var updatedAt: Date

    public init(fiveHour: Window?, sevenDay: Window?, updatedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.updatedAt = updatedAt
    }
}

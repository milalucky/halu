import Foundation
import HaluCore

// Claude Code hook: reads the event JSON from stdin and updates the session snapshot
// that Halu watches. Must stay silent on stdout and always exit 0, so it never
// changes what Claude does.

let input = FileHandle.standardInput.readDataToEndOfFile()
guard
    let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
    let sessionID = payload["session_id"] as? String,
    let event = payload["hook_event_name"] as? String
else { exit(0) }

let directory = HaluPaths.ensure(HaluPaths.claudeSessions)
let file = directory.appendingPathComponent("\(sessionID).json")
let now = Date()

if event == "SessionEnd" {
    try? FileManager.default.removeItem(at: file)
    exit(0)
}

var session: ClaudeSession
if let data = try? Data(contentsOf: file), let saved = try? HaluJSON.decoder().decode(ClaudeSession.self, from: data) {
    session = saved
} else {
    session = ClaudeSession(id: sessionID, cwd: payload["cwd"] as? String ?? "", now: now)
}
if let cwd = payload["cwd"] as? String, !cwd.isEmpty { session.cwd = cwd }

let toolName = payload["tool_name"] as? String ?? ""
let toolInput = payload["tool_input"] as? [String: Any] ?? [:]

func steps(from list: Any?) -> [ClaudeStep]? {
    guard let items = list as? [[String: Any]] else { return nil }
    return items.compactMap { item in
        guard let content = item["content"] as? String else { return nil }
        return ClaudeStep(content: content, status: item["status"] as? String ?? "pending")
    }
}

/// Mirrors the task-list tools (CLI `TodoWrite` and the desktop app's plan tool) into `steps`.
func applyPlan() {
    if toolName == "TodoWrite", let todos = steps(from: toolInput["todos"]) {
        session.steps = todos
        return
    }
    if toolName.hasSuffix("wrap_up") {
        for index in session.steps.indices { session.steps[index].status = "completed" }
        return
    }
    guard toolName.hasSuffix("update_plan") else { return }
    if let items = steps(from: toolInput["items"]) {
        session.steps = items
    }
    if let done = toolInput["done"] as? [Int] {
        for number in done where session.steps.indices.contains(number - 1) {
            session.steps[number - 1].status = "completed"
        }
    }
    if toolInput["advance"] as? Bool == true {
        if let current = session.steps.firstIndex(where: { $0.status == "in_progress" }) {
            session.steps[current].status = "completed"
        }
        if let next = session.steps.firstIndex(where: { $0.status == "pending" }) {
            session.steps[next].status = "in_progress"
        }
    }
    if let start = toolInput["start"] as? Int, session.steps.indices.contains(start - 1) {
        session.steps[start - 1].status = "in_progress"
    }
}

switch event {
case "SessionStart":
    if session.status != .working { session.status = .idle }
case "UserPromptSubmit":
    session.status = .working
    session.message = nil
    session.turnStartedAt = now
    if session.title.isEmpty, let prompt = payload["prompt"] as? String {
        let line = prompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        session.title = String(line.prefix(90))
    }
case "PreToolUse":
    applyPlan()
    if toolName == "AskUserQuestion" {
        session.status = .needsInput
        session.message = "Has a question for you"
    } else if toolName == "ExitPlanMode" {
        session.status = .needsInput
        session.message = "Plan is ready for review"
    } else {
        session.status = .working
        session.message = nil
    }
case "PostToolUse":
    session.status = .working
    session.message = nil
case "PermissionRequest":
    session.status = .needsInput
    session.message = toolName.isEmpty ? "Waiting for permission" : "Wants to use \(toolName)"
case "Notification":
    let message = payload["message"] as? String ?? ""
    let type = payload["notification_type"] as? String ?? ""
    let isIdleReminder = type == "idle_prompt" || message.localizedCaseInsensitiveContains("waiting for your input")
    if !isIdleReminder {
        session.status = .needsInput
        session.message = message.isEmpty ? nil : message
    }
case "Stop":
    session.status = .done
    session.message = nil
default:
    break
}

session.updatedAt = now
if let data = try? HaluJSON.encoder().encode(session) {
    try? data.write(to: file, options: .atomic)
}
exit(0)

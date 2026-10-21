import Foundation
import HaluCore

// Claude Code hook: reads the event JSON from stdin and updates the session snapshot that Halu
// watches. It always exits 0 and stays silent on stdout, except in two cases where Halu answers for
// you: a permission request (Allow / Always / Deny from the notch) and an AskUserQuestion prompt.
// It then waits for Halu's answer and prints the decision; with no answer (Halu not running, timed
// out, or "Answer in terminal") it stays silent and Claude Code asks in the terminal as usual.
//
// `halu-hook statusline` is the Claude Code status line: it saves plan usage for Halu's header.

let input = FileHandle.standardInput.readDataToEndOfFile()

if CommandLine.arguments.dropFirst().first == "statusline" {
    runStatusLine(input)
    exit(0)
}
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

if event == "PermissionRequest" || (event == "PreToolUse" && toolName == "AskUserQuestion") {
    askHalu(event: event, payload: payload, session: session)
}
exit(0)

// MARK: Answering from the notch

/// Halu touches its heartbeat every few seconds; an old one means it isn't running.
func haluIsRunning() -> Bool {
    guard let modified = (try? FileManager.default.attributesOfItem(atPath: HaluPaths.heartbeat.path))?[.modificationDate] as? Date
    else { return false }
    return Date().timeIntervalSince(modified) < 15
}

func summary(of input: [String: Any]) -> String {
    for key in ["command", "file_path", "url", "path", "pattern", "query", "notebook_path"] {
        if let value = input[key] as? String, !value.isEmpty { return value }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return "" }
    return String(String(decoding: data, as: UTF8.self).prefix(400))
}

func askHalu(event: String, payload: [String: Any], session: ClaudeSession) {
    guard haluIsRunning() else { return }
    let isQuestion = event == "PreToolUse"
    let questions: [ClaudeRequest.Question] = (toolInput["questions"] as? [[String: Any]] ?? []).compactMap { item -> ClaudeRequest.Question? in
        guard let text = item["question"] as? String else { return nil }
        let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> ClaudeRequest.Option? in
            guard let label = option["label"] as? String else { return nil }
            return ClaudeRequest.Option(label: label, description: option["description"] as? String)
        }
        return ClaudeRequest.Question(question: text, header: item["header"] as? String, options: options,
                                      multiSelect: item["multiSelect"] as? Bool)
    }
    if isQuestion && questions.isEmpty { return }
    let suggestions = payload["permission_suggestions"] as? [Any] ?? []
    let id = UUID().uuidString
    let request = ClaudeRequest(id: id, kind: isQuestion ? .question : .permission, sessionID: session.id, project: session.project,
                                toolName: toolName, summary: summary(of: toolInput), questions: questions,
                                canAlwaysAllow: !suggestions.isEmpty, createdAt: Date())
    let requestFile = HaluPaths.requestFile(for: id)
    let answerFile = HaluPaths.answerFile(for: id)
    HaluPaths.ensure(HaluPaths.claudeRequests)
    guard let data = try? HaluJSON.encoder().encode(request), (try? data.write(to: requestFile, options: .atomic)) != nil else { return }
    defer {
        try? FileManager.default.removeItem(at: requestFile)
        try? FileManager.default.removeItem(at: answerFile)
    }

    // Wait well inside the hook's timeout (set to 120 s by Halu), then let the terminal ask.
    let deadline = Date().addingTimeInterval(110)
    var answer: ClaudeAnswer?
    while Date() < deadline {
        if let data = try? Data(contentsOf: answerFile), let decoded = try? HaluJSON.decoder().decode(ClaudeAnswer.self, from: data) {
            answer = decoded
            break
        }
        guard haluIsRunning() else { return }
        Thread.sleep(forTimeInterval: 0.25)
    }
    guard let answer, answer.decision != .terminal else { return }

    var output: [String: Any]
    if isQuestion {
        guard let answers = answer.answers, answer.decision != .deny else { return }
        var updated = toolInput
        updated["answers"] = answers
        output = ["hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated]
    } else {
        var decision: [String: Any]
        switch answer.decision {
        case .allow: decision = ["behavior": "allow"]
        case .always: decision = ["behavior": "allow", "updatedPermissions": suggestions]
        default: decision = ["behavior": "deny", "message": "Declined from Halu."]
        }
        output = ["hookEventName": "PermissionRequest", "decision": decision]
    }
    if let data = try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": output]) {
        FileHandle.standardOutput.write(data)
    }
}

// MARK: Status line

/// Saves the plan usage Claude Code reports and prints a short status line.
func runStatusLine(_ input: Data) {
    guard let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { return }
    let limits = payload["rate_limits"] as? [String: Any] ?? [:]
    func window(_ key: String) -> ClaudeUsage.Window? {
        guard let item = limits[key] as? [String: Any], let used = item["used_percentage"] as? Double else { return nil }
        return ClaudeUsage.Window(usedPercentage: used, resetsAt: (item["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }
    let usage = ClaudeUsage(fiveHour: window("five_hour"), sevenDay: window("seven_day"), updatedAt: Date())
    if usage.fiveHour != nil || usage.sevenDay != nil, let data = try? HaluJSON.encoder().encode(usage) {
        HaluPaths.ensure(HaluPaths.support)
        try? data.write(to: HaluPaths.claudeUsage, options: .atomic)
    }
    var parts: [String] = []
    if let model = (payload["model"] as? [String: Any])?["display_name"] as? String { parts.append(model) }
    if let context = (payload["context_window"] as? [String: Any])?["used_percentage"] as? Double { parts.append("context \(Int(context))%") }
    if let five = usage.fiveHour { parts.append("5h \(Int(five.usedPercentage))%") }
    if let week = usage.sevenDay { parts.append("week \(Int(week.usedPercentage))%") }
    print(parts.joined(separator: " · "))
}

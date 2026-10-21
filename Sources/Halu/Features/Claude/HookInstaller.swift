import Foundation

/// Registers `halu-hook` in ~/.claude/settings.json so Claude Code (CLI and the desktop app)
/// reports session status. Keeps a backup and leaves every existing hook in place.
enum HookInstaller {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                         "PermissionRequest", "Notification", "Stop", "SessionEnd"]
    private static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PermissionRequest"]

    static var claudeDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude") }
    static var settingsURL: URL { claudeDirectory.appendingPathComponent("settings.json") }
    static var hookURL: URL { claudeDirectory.appendingPathComponent("hooks/halu-hook") }

    static var isInstalled: Bool {
        guard let text = try? String(contentsOf: settingsURL, encoding: .utf8) else { return false }
        return text.contains(hookURL.path)
    }

    enum InstallError: LocalizedError {
        case missingHookBinary
        case unreadableSettings

        var errorDescription: String? {
            switch self {
            case .missingHookBinary: "halu-hook is missing from the app bundle."
            case .unreadableSettings: "~/.claude/settings.json is not valid JSON, so Halu left it untouched."
            }
        }
    }

    /// Copies the bundled hook next to the other Claude hooks (also called on launch to keep it current).
    static func refreshHookBinary() throws {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "halu-hook") else { throw InstallError.missingHookBinary }
        let manager = FileManager.default
        try manager.createDirectory(at: hookURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: hookURL.path) { try manager.removeItem(at: hookURL) }
        try manager.copyItem(at: bundled, to: hookURL)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
    }

    static func install() throws {
        try refreshHookBinary()

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.unreadableSettings
            }
            settings = parsed
            try data.write(to: settingsURL.appendingPathExtension("halu-backup"), options: .atomic)
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let command: [String: Any] = ["type": "command", "command": hookURL.path, "timeout": 5]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let present = groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == hookURL.path }
            }
            guard !present else { continue }
            var group: [String: Any] = ["hooks": [command]]
            if toolEvents.contains(event) { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks

        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}

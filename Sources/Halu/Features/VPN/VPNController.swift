import AppKit

/// VPN switcher. Finds every VPN the Mac knows about and switches it on or off:
/// - VPNs registered with macOS (Outline, WireGuard, built-in IKEv2/L2TP…) through `scutil --nc`;
/// - Pritunl profiles in the client's system store through its own `pritunl-client` tool, so the
///   Pritunl service handles the keys and Halu never touches them;
/// - other VPN apps (AmneziaVPN, Pritunl profiles only in its window) can't be driven from outside:
///   they are listed to open.
@MainActor
final class VPNController: ObservableObject {
    struct Connection: Identifiable, Equatable {
        enum Kind: Equatable { case system, pritunl }
        enum State: Equatable { case off, connecting, on }

        var id: String
        var name: String
        var provider: String
        var kind: Kind
        var state: State
    }

    struct App: Identifiable, Equatable {
        var id: String { bundleID }
        var name: String
        var bundleID: String
    }

    @Published private(set) var connections: [Connection] = []
    @Published private(set) var apps: [App] = []
    private nonisolated static let pritunlTool = "/Applications/Pritunl.app/Contents/Resources/pritunl-client"
    /// VPN apps with no outside control: shown to open.
    private static let knownApps: [(bundleID: String, name: String)] = [
        ("com.yourcompany.AmneziaVPN", "AmneziaVPN"),
        ("com.electron.pritunl", "Pritunl"),
    ]
    private let queue = DispatchQueue(label: "halu.vpn", qos: .userInitiated)
    private var timer: Timer?

    var isOn: Bool { connections.contains { $0.state == .on } }
    var isConnecting: Bool { connections.contains { $0.state == .connecting } }

    func start() {
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func refresh() {
        queue.async {
            let found = Self.systemConnections() + Self.pritunlConnections()
            let apps = Self.knownApps.compactMap { app -> App? in
                guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil,
                      !(app.name == "Pritunl" && found.contains { $0.kind == .pritunl }) else { return nil }
                return App(name: app.name, bundleID: app.bundleID)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if found != self.connections { self.connections = found }
                    if apps != self.apps { self.apps = apps }
                }
            }
        }
    }

    func set(_ connection: Connection, on: Bool) {
        if on {
            // One tunnel at a time: switching to another VPN turns the current one off.
            for other in connections where other.id != connection.id && other.state != .off { set(other, on: false) }
        }
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index].state = on ? .connecting : .off
        }
        queue.async {
            switch connection.kind {
            case .system: Self.run("/usr/sbin/scutil", ["--nc", on ? "start" : "stop", connection.id])
            case .pritunl: Self.run(Self.pritunlTool, [on ? "start" : "stop", connection.id])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { self.refresh() } }
        }
    }

    func open(_ app: App) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Sources

    /// Lines like: `* (Connected)   8201B75A-… VPN (org.outline.macos.client) "KZ - Pavlodar"   [VPN:org.outline.macos.client]`
    private nonisolated static func systemConnections() -> [Connection] {
        guard let output = run("/usr/sbin/scutil", ["--nc", "list"]) else { return [] }
        let pattern = #"\((\w[^)]*)\)\s+([0-9A-F-]{36})\s+\S+\s+\(([^)]*)\)\s+"(.*)"\s+\["#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return output.split(separator: "\n").compactMap { line -> Connection? in
            let text = String(line)
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let status = Range(match.range(at: 1), in: text), let id = Range(match.range(at: 2), in: text),
                  let provider = Range(match.range(at: 3), in: text), let name = Range(match.range(at: 4), in: text) else { return nil }
            let state: Connection.State = switch text[status] {
            case "Connected": .on
            case "Connecting", "Disconnecting": .connecting
            default: .off
            }
            return Connection(id: String(text[id]), name: String(text[name]), provider: providerName(String(text[provider])),
                              kind: .system, state: state)
        }
    }

    private nonisolated static func providerName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.isEmpty ? "macOS" : bundleID.split(separator: ".").last.map(String.init)?.capitalized ?? bundleID
    }

    private nonisolated static func pritunlConnections() -> [Connection] {
        guard FileManager.default.isExecutableFile(atPath: pritunlTool),
              let output = run(pritunlTool, ["list", "-j"]),
              let rows = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> Connection? in
            guard let id = row["id"] as? String else { return nil }
            let status = ((row["status"] ?? row["state"]) as? String ?? "").lowercased()
            let state: Connection.State = status.contains("connecting") ? .connecting
                : (status.contains("active") || status.contains("connected")) && !status.contains("inactive") ? .on : .off
            return Connection(id: id, name: row["name"] as? String ?? id, provider: "Pritunl", kind: .pritunl, state: state)
        }
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

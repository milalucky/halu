import AppKit

/// VPN switcher. Finds every VPN the Mac knows about and switches it on or off:
/// - VPNs registered with macOS (Outline, WireGuard, built-in IKEv2/L2TP…) through `scutil --nc`;
/// - Pritunl profiles in the client's system store through its own `pritunl-client` tool, so the
///   Pritunl service handles the keys and Halu never touches them;
/// - other VPN apps (AmneziaVPN, Pritunl profiles only in its window) can't be driven from outside:
///   they are listed to open.
///
/// Servers that answer a ping show their latency, measured past any running tunnel (bound to the
/// Wi-Fi or Ethernet port). Many VPN servers ignore pings, so silence isn't failure: what counts is
/// whether a connection comes up. One that doesn't within `connectTimeout` is dropped and the next
/// server of the same VPN is tried, quickest first.
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
    /// Ping round trip per connection id, in milliseconds; nil when the server didn't answer.
    @Published private(set) var latency: [String: Double?] = [:]
    /// What auto-switching is doing, e.g. "MSK didn't connect · trying SPB".
    @Published private(set) var status: String?
    /// Servers that recently failed to connect, by id.
    @Published private(set) var failed: [String: Date] = [:]

    private let connectTimeout: TimeInterval = 25
    /// The server being connected and the ones still to try after it.
    private var attempt: (id: String, fallbacks: [String], started: Date)?
    private var pingTimer: Timer?
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
        let pingTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ping() }
        }
        RunLoop.main.add(pingTimer, forMode: .common)
        self.pingTimer = pingTimer
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.ping() }
    }

    /// Picks a server and keeps going down the list until one connects.
    func connect(_ connection: Connection) {
        let others = connections.filter { $0.provider == connection.provider && $0.id != connection.id }
        attempt = (connection.id, ranked(others).map(\.id), Date())
        status = nil
        set(connection, on: true)
    }

    /// The quickest server that answers, then silent ones, skipping recent failures.
    func connectFastest() {
        let candidates = ranked(connections.filter { $0.kind == .pritunl }.isEmpty ? connections : connections.filter { $0.kind == .pritunl })
        guard let first = candidates.first else { return }
        connect(first)
    }

    private func ranked(_ list: [Connection]) -> [Connection] {
        let recentFailure = { (id: String) in self.failed[id].map { Date().timeIntervalSince($0) < 600 } ?? false }
        return list.sorted { a, b in
            if recentFailure(a.id) != recentFailure(b.id) { return !recentFailure(a.id) }
            let la = latency[a.id] ?? nil, lb = latency[b.id] ?? nil
            switch (la, lb) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return false
            }
        }
    }

    /// Called on every refresh: gives up on a server that's taking too long and tries the next.
    private func checkAttempt() {
        guard let current = attempt, let connection = connections.first(where: { $0.id == current.id }) else { return }
        if connection.state == .on {
            failed[connection.id] = nil
            attempt = nil
            status = nil
            return
        }
        guard Date().timeIntervalSince(current.started) > connectTimeout else { return }
        failed[connection.id] = Date()
        set(connection, on: false)
        guard let nextID = current.fallbacks.first, let next = connections.first(where: { $0.id == nextID }) else {
            attempt = nil
            status = "\(connection.name) didn't connect, and no other server is left"
            return
        }
        status = "\(connection.name) didn't connect · trying \(next.name)"
        attempt = (next.id, Array(current.fallbacks.dropFirst()), Date())
        // Give the previous tunnel a moment to close.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.set(next, on: true) }
    }

    /// Pings every server whose address Halu knows, bypassing any VPN that's on.
    func ping() {
        let servers = connections.map { ($0.id, $0.name) }
        queue.async {
            let hosts = Self.pritunlHosts()
            let targets = Dictionary(servers.compactMap { id, name in hosts[name].map { (id, $0) } }, uniquingKeysWith: { a, _ in a })
            guard !targets.isEmpty else { return }
            let port = Self.physicalInterface()
            var results: [String: Double?] = [:]
            let group = DispatchGroup()
            let lock = NSLock()
            for (id, host) in targets {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let ms = Self.pingOnce(host, interface: port)
                    lock.withLock { results[id] = ms }
                    group.leave()
                }
            }
            group.wait()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.latency = results } }
        }
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
                    self.checkAttempt()
                }
            }
        }
    }

    func set(_ connection: Connection, on: Bool) {
        if !on, attempt?.id == connection.id, connections.first(where: { $0.id == connection.id })?.state == .on {
            attempt = nil // Turned off by hand.
        }
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

    // MARK: Ping

    /// Server addresses from the Pritunl app's profiles, by server name ("MSK"). Only the `remote`
    /// line is read; the keys in those files are never touched.
    private nonisolated static func pritunlHosts() -> [String: String] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/pritunl/profiles")
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [:] }
        var hosts: [String: String] = [:]
        for conf in files where conf.pathExtension == "conf" {
            guard let data = try? Data(contentsOf: conf),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let server = json["server"] as? String,
                  let ovpn = try? String(contentsOf: conf.deletingPathExtension().appendingPathExtension("ovpn"), encoding: .utf8),
                  let remote = ovpn.split(separator: "\n").first(where: { $0.hasPrefix("remote ") }) else { continue }
            let parts = remote.split(separator: " ")
            if parts.count > 1 { hosts[server] = String(parts[1]) }
        }
        return hosts
    }

    /// The Wi-Fi or Ethernet port that has an address, so pings skip the tunnel.
    private nonisolated static func physicalInterface() -> String? {
        guard let ports = run("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return nil }
        let devices = ports.split(separator: "\n").filter { $0.hasPrefix("Device: ") }.map { String($0.dropFirst(8)) }
        return devices.first { (run("/usr/sbin/ipconfig", ["getifaddr", $0]) ?? "").contains(".") }
    }

    private nonisolated static func pingOnce(_ host: String, interface: String?) -> Double? {
        var arguments = ["-c", "1", "-W", "1500", "-q", host]
        if let interface { arguments = ["-b", interface] + arguments }
        guard let output = run("/sbin/ping", arguments),
              let line = output.split(separator: "\n").first(where: { $0.contains("round-trip") }),
              let values = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces).split(separator: "/").first else { return nil }
        return Double(values)
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
            // `connected` is the tunnel; `run_state` "Active" without it means still connecting.
            let connected = row["connected"] as? Bool ?? false
            let running = (row["run_state"] as? String ?? "").lowercased() == "active"
            let state: Connection.State = connected ? .on : running ? .connecting : .off
            // "m.zharkevich (MSK)" → "MSK": the server is what tells profiles apart.
            var name = row["name"] as? String ?? id
            if let open = name.lastIndex(of: "("), name.hasSuffix(")") { name = String(name[name.index(after: open)..<name.index(before: name.endIndex)]) }
            return Connection(id: id, name: name, provider: "Pritunl", kind: .pritunl, state: state)
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

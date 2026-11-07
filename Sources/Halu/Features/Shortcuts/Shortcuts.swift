import AppKit
import SwiftUI

/// Your macOS Shortcuts as one-click tiles, run through the system `shortcuts` tool. Pinned ones
/// come first.
@MainActor
final class ShortcutsStore: ObservableObject {
    enum RunState: Equatable { case running, done, failed(String) }

    @Published private(set) var names: [String] = []
    @Published private(set) var states: [String: RunState] = [:]
    @Published private(set) var pinned: [String] = UserDefaults.standard.stringArray(forKey: "shortcuts.pinned") ?? []
    @Published var query = ""

    var visible: [String] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let list = query.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(query) }
        return list.filter(pinned.contains) + list.filter { !pinned.contains($0) }
    }

    func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let output = Self.shortcuts(["list"]).output
            let names = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.names = names } }
        }
    }

    func run(_ name: String) {
        states[name] = .running
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.shortcuts(["run", name])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.states[name] = result.ok ? .done : .failed(result.error.isEmpty ? "Didn't finish" : result.error)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if self.states[name] != .running { self.states[name] = nil } }
                }
            }
        }
    }

    func togglePin(_ name: String) {
        if let index = pinned.firstIndex(of: name) { pinned.remove(at: index) } else { pinned.append(name) }
        UserDefaults.standard.set(pinned, forKey: "shortcuts.pinned")
    }

    func openApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private nonisolated static func shortcuts(_ arguments: [String]) -> (ok: Bool, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        guard (try? process.run()) != nil else { return (false, "", "Can't run shortcuts") }
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus == 0, output, error.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct ShortcutsView: View {
    @ObservedObject var store: ShortcutsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                InputField(placeholder: "Search your shortcuts", icon: "magnifyingglass", text: $store.query)
                IconButton(icon: "arrow.clockwise", help: "Reload", size: 12, action: store.load)
                IconButton(icon: "square.and.pencil", help: "Open the Shortcuts app", size: 12, action: store.openApp)
            }
            if store.names.isEmpty {
                EmptyState(icon: "square.stack.3d.up", title: "No shortcuts yet",
                           subtitle: "Make one in the Shortcuts app and it shows up here to run in one click.",
                           action: ("Open Shortcuts", store.openApp))
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                        ForEach(store.visible, id: \.self) { ShortcutTile(name: $0, store: store) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .onAppear(perform: store.load)
    }
}

private struct ShortcutTile: View {
    let name: String
    @ObservedObject var store: ShortcutsStore
    @State private var hovering = false

    var body: some View {
        let tint = TagColor.of(name)
        let state = store.states[name]
        Button { store.run(name) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Group {
                        switch state {
                        case .running: ProgressView().controlSize(.small)
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.white)
                        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
                        case nil: Image(systemName: "play.fill").foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    .font(.system(size: 13, weight: .bold))
                    Spacer()
                    if store.pinned.contains(name) { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.8)) }
                }
                Spacer(minLength: 0)
                Text(name).font(Theme.body(12, weight: .semibold)).foregroundStyle(.white).lineLimit(2).multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .scaleEffect(hovering ? 1.03 : (state == .running ? 0.97 : 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hovering)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: state)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help({ if case .failed(let message) = state { return message }; return "Run \(name)" }())
        .contextMenu {
            Button(store.pinned.contains(name) ? "Unpin" : "Pin to the top") { store.togglePin(name) }
        }
    }
}

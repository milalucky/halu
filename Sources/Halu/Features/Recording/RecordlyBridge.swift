import AppKit
import ApplicationServices
import SwiftUI

/// A remote for Recordly (dev.recordly.app), the screen recorder. Recordly has no URL scheme,
/// AppleScript or global shortcut, so:
/// - "Record" brings Recordly forward with its window (it has no shortcut or command to start a
///   recording from outside), or opens the macOS recording bar if that's chosen in Settings;
/// - while it records it shows a menu bar icon; Halu reads that through Accessibility to know a
///   recording is running, and presses its "Stop Recording" item to stop.
@MainActor
final class RecordlyBridge: ObservableObject {
    static let bundleID = "dev.recordly.app"

    @Published private(set) var isInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: RecordlyBridge.bundleID) != nil
    @Published private(set) var isRecording = false
    @Published private(set) var since: Date?

    enum Recorder: String, CaseIterable, Identifiable {
        case recordly = "Recordly", macOS = "macOS"
        var id: String { rawValue }
    }

    /// What the record button opens: Recordly's own window, or the macOS screen recording bar (⌘⇧5).
    @Published var recorder = Recorder(rawValue: UserDefaults.standard.string(forKey: "recordly.recorder") ?? "") ?? .recordly {
        didSet { UserDefaults.standard.set(recorder.rawValue, forKey: "recordly.recorder") }
    }

    private var timer: Timer?

    /// Starts a recording the chosen way. Recordly has no way to start recording from outside, so
    /// Halu brings its window forward, where you pick the area and press record.
    func record() {
        Services.shared.collapsePanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            switch recorder {
            case .recordly where isInstalled: showControls()
            default: recordWithMacOS()
            }
        }
    }

    /// The macOS screenshot and screen recording bar; recordings land in the screenshot folder,
    /// so they show up on the Shelf.
    func recordWithMacOS() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.screenshot.launcher") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func start() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    /// Brings Recordly forward (launching it if needed) with its window showing.
    func showControls() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            // The reopen event makes Electron show its window again if it was closed.
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                NSAppleScript(source: "tell application id \"\(Self.bundleID)\" to reopen")?.executeAndReturnError(&error)
            }
        }
    }

    /// Presses "Stop Recording" in Recordly's menu bar icon.
    func stop() {
        guard let item = trayItem() else { return }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        // The menu opens; find the item and press it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let menu = Self.children(of: item).first else { return }
            for entry in Self.children(of: menu) where (Self.title(of: entry) ?? "").localizedCaseInsensitiveContains("stop") {
                AXUIElementPerformAction(entry, kAXPressAction as CFString)
                return
            }
            // Nothing to stop: close the menu again.
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            self.refresh()
        }
    }

    func openApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func refresh() {
        isInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
        let recording = trayItem() != nil
        if recording != isRecording {
            isRecording = recording
            since = recording ? Date() : nil
        }
    }

    /// Recordly's menu bar icon, present only while it records.
    private func trayItem() -> AXUIElement? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var extras: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXExtrasMenuBarAttribute as CFString, &extras) == .success,
              let bar = extras, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        return Self.children(of: bar as! AXUIElement).first
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        return value as? String
    }
}

/// Header button: a click opens Recordly's controls; while it records the dot glows red with the
/// time, and a click stops. Right-click for more.
struct RecordButton: View {
    @ObservedObject var recordly: RecordlyBridge
    @State private var hovering = false

    var body: some View {
        if recordly.isInstalled || recordly.recorder == .macOS {
            Button {
                recordly.isRecording ? recordly.stop() : recordly.record()
            } label: {
                ZStack {
                    if recordly.isRecording {
                        Circle().fill(Theme.red).frame(width: 9, height: 9)
                            .shadow(color: Theme.red, radius: 4)
                            .modifier(Pulse())
                    } else {
                        Image(systemName: "record.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(hovering ? Theme.primary : Theme.secondary)
                    }
                }
                .headerButton(active: recordly.isRecording, tint: Theme.red, hovering: hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
            .contextMenu {
                if recordly.isRecording {
                    Button("Stop recording", action: recordly.stop)
                }
                Button("Record with Recordly", action: recordly.showControls)
                Button("Record with macOS (⌘⇧5)", action: recordly.recordWithMacOS)
            }
        }
    }

    private var help: String {
        guard recordly.isRecording else {
            return recordly.recorder == .recordly ? "Record the screen with Recordly · right-click for macOS recording" : "Record the screen (macOS) · right-click for Recordly"
        }
        let seconds = Int(Date().timeIntervalSince(recordly.since ?? Date()))
        return "Recording · \(seconds / 60):\(String(format: "%02d", seconds % 60)) · click to stop"
    }

    private struct Pulse: ViewModifier {
        @State private var on = false
        func body(content: Content) -> some View {
            content.opacity(on ? 0.45 : 1)
                .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true } }
        }
    }
}

import AppKit
import ApplicationServices
import SwiftUI

/// A remote for Recordly (dev.recordly.app), the screen recorder. Recordly has no URL scheme,
/// AppleScript or global shortcut, so:
/// - "Record" presses the user's own shortcut for starting a recording (⌥3, set in Settings), which
///   brings up Recordly's area picker; without a shortcut it sends the reopen event, which shows its
///   controls;
/// - while it records it shows a menu bar icon; Halu reads that through Accessibility to know a
///   recording is running, and presses its "Stop Recording" item to stop.
@MainActor
final class RecordlyBridge: ObservableObject {
    static let bundleID = "dev.recordly.app"

    @Published private(set) var isInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: RecordlyBridge.bundleID) != nil
    @Published private(set) var isRecording = false
    @Published private(set) var since: Date?

    /// The keyboard shortcut that starts a recording, as "⌥3"; empty to use Recordly's window instead.
    @Published var shortcut = UserDefaults.standard.string(forKey: "recordly.shortcut") ?? "⌥3" {
        didSet { UserDefaults.standard.set(shortcut, forKey: "recordly.shortcut") }
    }

    private var timer: Timer?

    /// Starts a recording: the shortcut if there is one, else Recordly's own controls.
    func record() {
        Services.shared.collapsePanel()
        if let (key, flags) = Self.parse(shortcut), AXIsProcessTrusted() {
            // Let the panel close first, so the area picker isn't covered.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let source = CGEventSource(stateID: .combinedSessionState)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
                    event?.flags = flags
                    event?.post(tap: .cghidEventTap)
                }
            }
        } else {
            showControls()
        }
    }

    /// "⌥3", "⌃⇧R", "⌘⇧5" → key code and modifier flags.
    private static func parse(_ text: String) -> (CGKeyCode, CGEventFlags)? {
        var flags: CGEventFlags = []
        var rest = ""
        for char in text {
            switch char {
            case "⌘": flags.insert(.maskCommand)
            case "⌥": flags.insert(.maskAlternate)
            case "⌃": flags.insert(.maskControl)
            case "⇧": flags.insert(.maskShift)
            default: rest.append(char)
            }
        }
        let keys: [String: CGKeyCode] = [
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
            "A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5, "H": 4, "I": 34, "J": 38, "K": 40, "L": 37, "M": 46,
            "N": 45, "O": 31, "P": 35, "Q": 12, "R": 15, "S": 1, "T": 17, "U": 32, "V": 9, "W": 13, "X": 7, "Y": 16, "Z": 6,
        ]
        guard !flags.isEmpty, let key = keys[rest.uppercased().trimmingCharacters(in: .whitespaces)] else { return nil }
        return (key, flags)
    }

    func start() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    /// Opens Recordly's controls (launching it if needed).
    func showControls() {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application id \"\(Self.bundleID)\" to reopen")?.executeAndReturnError(&error)
            NSAppleScript(source: "tell application id \"\(Self.bundleID)\" to activate")?.executeAndReturnError(&error)
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
        if recordly.isInstalled {
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
                Button(recordly.isRecording ? "Stop recording" : "Record (\(recordly.shortcut))") {
                    recordly.isRecording ? recordly.stop() : recordly.record()
                }
                Button("Show Recordly's controls", action: recordly.showControls)
                Button("Open Recordly", action: recordly.openApp)
            }
        }
    }

    private var help: String {
        guard recordly.isRecording else { return "Record the screen with Recordly (\(recordly.shortcut))" }
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

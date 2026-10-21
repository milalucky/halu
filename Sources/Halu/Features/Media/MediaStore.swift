import AppKit
import ApplicationServices
import CoreAudio

/// Whatever is making sound right now: a YouTube tab, Yandex Music, a podcast app.
struct MediaSource: Equatable {
    var pid: pid_t
    var appName: String
    var bundleID: String
    /// The app's front window title, e.g. "Song name – YouTube"; nil without Accessibility access.
    var title: String?
    var isPlaying: Bool
    var lastHeard: Date
}

/// Finds the app playing audio through Core Audio's process list (public API, no permission) and
/// controls it with the system media keys, which macOS routes to its current "now playing" app.
/// Window titles and media keys both need Accessibility access.
@MainActor
final class MediaStore: ObservableObject {
    /// False while the tab is turned off in Settings: background work pauses.
    var isActive: () -> Bool = { true }

    @Published private(set) var source: MediaSource?
    @Published private(set) var canControl = AXIsProcessTrusted()

    /// A paused source stays on screen this long, so it can be resumed.
    private let pausedLinger: TimeInterval = 30 * 60
    private var timer: Timer?

    func start() {
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func refresh() {
        guard isActive() else { return }
        canControl = AXIsProcessTrusted()
        let now = Date()
        if let playing = Self.appPlayingAudio() {
            var next = MediaSource(pid: playing.processIdentifier, appName: playing.localizedName ?? "Media",
                                   bundleID: playing.bundleIdentifier ?? "", title: nil, isPlaying: true, lastHeard: now)
            next.title = canControl ? Self.windowTitle(of: playing) : nil
            if next != source { source = next }
        } else if var current = source {
            let stillOpen = NSRunningApplication(processIdentifier: current.pid) != nil
            if !stillOpen || now.timeIntervalSince(current.lastHeard) > pausedLinger {
                source = nil
            } else if current.isPlaying {
                current.isPlaying = false
                source = current
            }
        }
    }

    var icon: NSImage? {
        source.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.icon }
    }

    func openApp() {
        NSRunningApplication(processIdentifier: source?.pid ?? 0)?.activate()
    }

    // MARK: Media keys

    enum MediaKey: Int32 {
        case playPause = 16, next = 17, previous = 18
    }

    func send(_ key: MediaKey) {
        guard AXIsProcessTrusted() else {
            requestAccess()
            return
        }
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
        if key == .playPause, var current = source {
            current.isPlaying.toggle()
            current.lastHeard = .now
            source = current
        }
    }

    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        canControl = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Core Audio

    /// Where audio and video usually come from. Some apps (Claude, call apps) keep an output open in
    /// silence, so these win whenever one of them is sending audio too.
    private static let mediaApps = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "ru.yandex.desktop.yandex-browser",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.operasoftware.Opera", "com.brave.Browser",
        "ru.yandex.desktop.music", "com.apple.Music", "com.spotify.client", "com.apple.podcasts", "com.apple.TV",
        "com.colliderli.iina", "org.videolan.vlc", "com.apple.QuickTimePlayerX",
    ]

    /// The app (not its helper process) that is sending audio to an output right now.
    private static func appPlayingAudio() -> NSRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var candidates: [NSRunningApplication] = []
        for object in processObjects() {
            guard uint32(object, kAudioProcessPropertyIsRunningOutput) != 0,
                  let pid = pid(object), pid != ownPID,
                  let app = owningApp(pid: pid, bundleID: string(object, kAudioProcessPropertyBundleID)),
                  app.processIdentifier != ownPID, !candidates.contains(app) else { continue }
            candidates.append(app)
        }
        return candidates.first { mediaApps.contains($0.bundleIdentifier ?? "") } ?? candidates.first
    }

    /// Browsers and Electron apps play sound from helper processes; map them to the app the user sees.
    private static func owningApp(pid: pid_t, bundleID: String?) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
        guard let bundleID else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if bundleID.hasPrefix("com.apple.WebKit") {
            return apps.first { $0.bundleIdentifier == "com.apple.Safari" }
        }
        // "com.google.Chrome.helper", "ru.yandex.desktop.music.helper.Renderer" → the app whose id prefixes it.
        return apps
            .filter { app in app.bundleIdentifier.map { bundleID.hasPrefix($0 + ".") } ?? false }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func pid(_ object: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value > 0 ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    // MARK: Accessibility

    private static let browserSuffixes = [" - Google Chrome", " — Google Chrome", " - Яндекс Браузер", " — Яндекс Браузер",
                                          " - Arc", " — Mozilla Firefox", " - Microsoft Edge"]

    private static func windowTitle(of app: NSRunningApplication) -> String? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &window) == .success
                || AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var title: CFTypeRef?
        // swiftlint:disable:next force_cast
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
              var text = title as? String, !text.isEmpty else { return nil }
        for suffix in browserSuffixes where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        return text
    }
}

import AppKit

/// What a browser tab with a <video> or <audio> reports about itself.
struct BrowserPlayback: Equatable {
    var window: Int
    var tab: Int
    var isPlaying: Bool
    var title: String
    var artist: String
    var artworkURL: URL?
    var position: TimeInterval
    var duration: TimeInterval
    var readAt: Date

    func position(at now: Date) -> TimeInterval {
        guard isPlaying else { return position }
        return min(duration > 0 ? duration : .greatestFiniteMagnitude, position + now.timeIntervalSince(readAt))
    }
}

/// Reads and drives the media element of a browser tab through the browser's own AppleScript
/// ("execute javascript" in Chromium browsers, "do JavaScript" in Safari). Both browsers need
/// "Allow JavaScript from Apple Events" turned on once. Unlike media keys, this never wakes up
/// Apple Music when the video is paused.
final class BrowserMedia: @unchecked Sendable {
    enum Failure: Error { case javaScriptOff, unsupported, failed }

    enum Command {
        case toggle, seek(TimeInterval), skip(TimeInterval), next, previous
    }

    static let chromium: Set<String> = [
        "com.google.Chrome", "ru.yandex.desktop.yandex-browser", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "com.operasoftware.Opera",
    ]

    static func supports(_ bundleID: String) -> Bool { chromium.contains(bundleID) || bundleID == "com.apple.Safari" }

    private let queue = DispatchQueue(label: "halu.browser-media", qos: .userInitiated)

    // Prefers the Media Session metadata sites publish (YouTube, Yandex Music), then the page title.
    private static let readScript = """
    (() => { const all = [...document.querySelectorAll('video, audio')].filter(m => m.duration > 0 || !m.paused);
      if (!all.length) return '';
      const m = all.find(x => !x.paused) || all[0];
      const meta = navigator.mediaSession && navigator.mediaSession.metadata;
      const art = meta && meta.artwork && meta.artwork.length ? meta.artwork[meta.artwork.length - 1].src : '';
      const og = document.querySelector('meta[property="og:image"]');
      return JSON.stringify({ playing: !m.paused, title: (meta && meta.title) || document.title,
        artist: (meta && meta.artist) || location.hostname.replace(/^www\\./, ''),
        art: art || (og && og.content) || '', time: m.currentTime, duration: isFinite(m.duration) ? m.duration : 0 });
    })()
    """

    /// Checks the tab that played last time first; scans every tab only when that one has no media.
    func read(_ bundleID: String, hint: (window: Int, tab: Int)?, _ done: @escaping @MainActor (Result<BrowserPlayback?, Failure>) -> Void) {
        queue.async {
            var result: Result<BrowserPlayback?, Failure>
            if let hint, case .success(let found?) = Self.readTab(bundleID, window: hint.window, tab: hint.tab) {
                result = .success(found)
            } else {
                result = Self.scan(bundleID)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    func send(_ command: Command, to bundleID: String, window: Int, tab: Int, _ done: @escaping @MainActor () -> Void) {
        let js: String
        switch command {
        case .toggle:
            js = "(() => { const m = [...document.querySelectorAll('video, audio')].find(x => !x.paused) || document.querySelector('video, audio'); if (m) { m.paused ? m.play() : m.pause(); } })()"
        case .seek(let seconds):
            js = "(() => { const m = document.querySelector('video, audio'); if (m) m.currentTime = \(seconds); })()"
        case .skip(let delta):
            js = "(() => { const m = [...document.querySelectorAll('video, audio')].find(x => !x.paused) || document.querySelector('video, audio'); if (m) m.currentTime = Math.max(0, m.currentTime + (\(delta))); })()"
        case .next:
            js = "(() => { const b = document.querySelector('.ytp-next-button, [aria-label*=\"Next\" i], [aria-label*=\"Следующ\" i]'); if (b) b.click(); })()"
        case .previous:
            js = "(() => { const b = document.querySelector('[aria-label*=\"Previous\" i], [aria-label*=\"Предыдущ\" i]'); if (b) b.click(); else history.back(); })()"
        }
        queue.async {
            _ = Self.execute(Self.runScript(js, bundleID: bundleID, window: window, tab: tab))
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }

    // MARK: AppleScript

    private static func scan(_ bundleID: String) -> Result<BrowserPlayback?, Failure> {
        let js = escape(readScript)
        let run = bundleID == "com.apple.Safari" ? "do JavaScript js in t" : "execute t javascript js"
        let source = """
        tell application id "\(bundleID)"
            set js to "\(js)"
            set fallback to ""
            set wi to 0
            repeat with w in windows
                set wi to wi + 1
                set ti to 0
                repeat with t in tabs of w
                    set ti to ti + 1
                    set r to \(run)
                    if r is not missing value and r is not "" then
                        if r contains "\\"playing\\":true" then return (wi as text) & "|" & (ti as text) & "|" & r
                        if fallback is "" then set fallback to (wi as text) & "|" & (ti as text) & "|" & r
                    end if
                end repeat
            end repeat
            return fallback
        end tell
        """
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String ?? "").lowercased()
            // Chrome and Safari refuse with a message about JavaScript from Apple Events.
            return .failure(message.contains("javascript") || message.contains("apple events") ? .javaScriptOff : .failed)
        }
        guard let text = output?.stringValue, !text.isEmpty else { return .success(nil) }
        return .success(parse(text))
    }

    private static func readTab(_ bundleID: String, window: Int, tab: Int) -> Result<BrowserPlayback?, Failure> {
        var error: NSDictionary?
        let output = NSAppleScript(source: runScript(readScript, bundleID: bundleID, window: window, tab: tab))?
            .executeAndReturnError(&error)
        guard error == nil, let text = output?.stringValue, !text.isEmpty else { return .success(nil) }
        return .success(parse("\(window)|\(tab)|\(text)"))
    }

    private static func parse(_ text: String) -> BrowserPlayback? {
        let parts = text.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3, let window = Int(parts[0]), let tab = Int(parts[1]),
              let data = parts[2].data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return BrowserPlayback(
            window: window, tab: tab,
            isPlaying: json["playing"] as? Bool ?? false,
            title: json["title"] as? String ?? "",
            artist: json["artist"] as? String ?? "",
            artworkURL: (json["art"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
            position: json["time"] as? Double ?? 0,
            duration: json["duration"] as? Double ?? 0,
            readAt: Date()
        )
    }

    private static func runScript(_ js: String, bundleID: String, window: Int, tab: Int) -> String {
        let target = "tab \(tab) of window \(window)"
        let run = bundleID == "com.apple.Safari" ? "do JavaScript \"\(escape(js))\" in \(target)"
                                                 : "execute \(target) javascript \"\(escape(js))\""
        return "tell application id \"\(bundleID)\" to \(run)"
    }

    @discardableResult
    private static func execute(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

import AppKit
import ApplicationServices

struct NowPlaying: Equatable {
    enum Player: String {
        case music = "Music"
        case spotify = "Spotify"

        var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    }

    var player: Player
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    var isPlaying: Bool
    /// When `position` was read, so the scrubber can keep moving between polls.
    var readAt: Date

    func position(at now: Date) -> TimeInterval {
        guard isPlaying else { return position }
        return min(duration > 0 ? duration : .greatestFiniteMagnitude, position + now.timeIntervalSince(readAt))
    }
}

/// Music and Spotify through their own AppleScript; any other source (a browser video,
/// a podcast app) through the system media keys, which go to whatever macOS is playing.
@MainActor
final class MediaStore: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var canSendMediaKeys = AXIsProcessTrusted()

    private let bridge = MediaBridge()
    private var timer: Timer?
    private var artworkKey: String?

    func start() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func refresh() {
        canSendMediaKeys = AXIsProcessTrusted()
        // Only ask players that are already open: scripting a closed app would launch it.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let players = [NowPlaying.Player.music, .spotify].filter { running.contains($0.bundleID) }
        guard !players.isEmpty else {
            if nowPlaying != nil { nowPlaying = nil; artwork = nil; artworkKey = nil }
            return
        }
        bridge.read(players) { [weak self] states in
            guard let self else { return }
            // The one that is playing wins; otherwise the first with a paused track.
            let pick = states.first { $0.isPlaying } ?? states.first
            if self.nowPlaying != pick { self.nowPlaying = pick }
            self.loadArtworkIfNeeded(pick)
        }
    }

    // MARK: Player commands

    func playPause() { command("playpause") }
    func next() { command("next track") }
    func previous() { command("previous track") }

    func seek(to seconds: TimeInterval) {
        guard var current = nowPlaying else { return }
        bridge.run("tell application \"\(current.player.rawValue)\" to set player position to \(Int(seconds))") { [weak self] in
            self?.refresh()
        }
        current.position = seconds
        current.readAt = .now
        nowPlaying = current
    }

    func openPlayer() {
        guard let player = nowPlaying?.player,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func command(_ verb: String) {
        guard let player = nowPlaying?.player else { return }
        if verb == "playpause", var current = nowPlaying {
            current.isPlaying.toggle()
            current.position = current.position(at: .now)
            current.readAt = .now
            nowPlaying = current
        }
        bridge.run("tell application \"\(player.rawValue)\" to \(verb)") { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.refresh() }
        }
    }

    // MARK: Media keys

    enum MediaKey: Int32 {
        case playPause = 16, next = 17, previous = 18
    }

    func send(_ key: MediaKey) {
        guard AXIsProcessTrusted() else {
            requestMediaKeyAccess()
            return
        }
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    func requestMediaKeyAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        canSendMediaKeys = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Artwork

    private func loadArtworkIfNeeded(_ playing: NowPlaying?) {
        guard let playing else {
            artwork = nil
            artworkKey = nil
            return
        }
        let key = "\(playing.player.rawValue)|\(playing.title)|\(playing.artist)|\(playing.album)"
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil
        bridge.artwork(for: playing.player) { [weak self] image in
            guard let self, self.artworkKey == key else { return }
            self.artwork = image
        }
    }
}

/// AppleScript calls on a background queue.
final class MediaBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "halu.media", qos: .userInitiated)

    func read(_ players: [NowPlaying.Player], _ done: @escaping @MainActor ([NowPlaying]) -> Void) {
        queue.async {
            let now = Date()
            let states = players.compactMap { player -> NowPlaying? in
                // Spotify reports duration in milliseconds, Music in seconds.
                let source = """
                tell application "\(player.rawValue)"
                    if player state is stopped then return {}
                    set t to current track
                    return {name of t, artist of t, album of t, duration of t, player position, (player state as text)}
                end tell
                """
                guard let output = Self.execute(source), output.numberOfItems >= 6 else { return nil }
                var duration = output.atIndex(4)?.doubleValue ?? 0
                if player == .spotify { duration /= 1000 }
                return NowPlaying(player: player,
                                  title: output.atIndex(1)?.stringValue ?? "",
                                  artist: output.atIndex(2)?.stringValue ?? "",
                                  album: output.atIndex(3)?.stringValue ?? "",
                                  duration: duration,
                                  position: output.atIndex(5)?.doubleValue ?? 0,
                                  isPlaying: output.atIndex(6)?.stringValue == "playing",
                                  readAt: now)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(states) } }
        }
    }

    func artwork(for player: NowPlaying.Player, _ done: @escaping @MainActor (NSImage?) -> Void) {
        queue.async {
            var image: NSImage?
            switch player {
            case .music:
                let output = Self.execute("tell application \"Music\" to get data of artwork 1 of current track")
                if let data = output?.data { image = NSImage(data: data) }
            case .spotify:
                if let link = Self.execute("tell application \"Spotify\" to get artwork url of current track")?.stringValue,
                   let url = URL(string: link), let data = try? Data(contentsOf: url) {
                    image = NSImage(data: data)
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(image) } }
        }
    }

    func run(_ source: String, _ done: @escaping @MainActor () -> Void) {
        queue.async {
            _ = Self.execute(source)
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }

    private static func execute(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? output : nil
    }
}

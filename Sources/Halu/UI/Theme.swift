import SwiftUI

enum Theme {
    /// The current tab's colour in the chosen style (lavender before anything is chosen).
    static var accent = Color(red: 0.70, green: 0.64, blue: 1.00)
    static let green = Color(red: 0.45, green: 0.86, blue: 0.62)
    static let orange = Color(red: 1.00, green: 0.66, blue: 0.36)
    static let red = Color(red: 1.00, green: 0.45, blue: 0.45)
    static let blue = Color(red: 0.50, green: 0.74, blue: 1.00)

    // Text and surfaces follow the light or dark look of where they're drawn (Settings → Appearance).
    static let primary = adaptive(dark: 0.92, light: 0.86)
    static let secondary = adaptive(dark: 0.55, light: 0.58)
    static let tertiary = adaptive(dark: 0.32, light: 0.38)
    /// Card fills: neutral in Minimal and Glass, tinted with the tab's colour in Playful and Neon.
    static var card: Color {
        switch Style.current {
        case .playful: accent.opacity(0.1)
        case .neon: accent.opacity(0.07)
        default: Color.white.opacity(0.055)
        }
    }

    static var cardHover: Color {
        switch Style.current {
        case .playful: accent.opacity(0.17)
        case .neon: accent.opacity(0.13)
        default: Color.white.opacity(0.095)
        }
    }
    static let hairline = adaptive(dark: 0.08, light: 0.1)

    /// Text on a `primary` fill (a selected chip): dark on the light chip of dark mode and the reverse.
    static let onPrimary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? NSColor.white : NSColor.black.withAlphaComponent(0.85)
    })

    /// White at `dark` opacity on dark backgrounds, black at `light` opacity on light ones.
    private static func adaptive(dark: CGFloat, light: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
                ? NSColor.black.withAlphaComponent(light)
                : NSColor.white.withAlphaComponent(dark)
        })
    }

    static func title(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func body(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func caption(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight) }
}

enum Fmt {
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    static let time = formatter("HH:mm")
    static let day = formatter("EEE, MMM d")
    static let headerDate = formatter("EEE d")

    static func ago(_ date: Date, now: Date = .now) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    static func until(_ date: Date, now: Date = .now) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "in \(minutes / 60)h" : "in \(minutes / 60)h \(rest)m"
    }

    static func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return day.string(from: date)
    }
}

/// Small JSON file in Application Support.
struct JSONFile<Value: Codable> {
    let url: URL

    init(_ name: String) {
        url = HaluStorage.directory.appendingPathComponent(name)
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum HaluStorage {
    static var directory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Halu", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

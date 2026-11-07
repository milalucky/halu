import SwiftUI

/// The theme (Settings → Theme). Each one changes the whole panel, not just an accent:
/// - Minimal: pure black, monochrome, flat.
/// - Playful: every tab its own soft colour — a coloured glow in the panel's corner, tinted cards,
///   coloured icons, bouncy motion.
/// - Neon: blue-black, electric colours, a shimmering gradient rim and glowing highlights.
/// - Glass: dark Liquid Glass you can see the desktop through, with the tab colours.
/// - Aurora (default): Liquid Glass with soft colour light, a floating glass capsule for the tabs
///   and frosted cards.
enum Style: String, CaseIterable, Identifiable {
    case aurora = "Aurora", minimal = "Minimal", playful = "Playful", neon = "Neon", glass = "Glass"
    var id: String { rawValue }

    /// The theme in use; read while drawing. AppModel keeps it current.
    static var current: Style = {
        let defaults = UserDefaults.standard
        // Aurora is the new look: switch to it once; picking another theme afterwards sticks.
        if !defaults.bool(forKey: "style.auroraIntroduced") {
            defaults.set(true, forKey: "style.auroraIntroduced")
            defaults.set(Style.aurora.rawValue, forKey: "style")
            return .aurora
        }
        return Style(rawValue: defaults.string(forKey: "style") ?? "") ?? .aurora
    }()

    var glows: Bool { self == .neon }
    var isColourful: Bool { self != .minimal }

    var icon: String {
        switch self {
        case .minimal: "circle.lefthalf.filled"
        case .playful: "paintpalette.fill"
        case .neon: "sparkles"
        case .glass: "drop.fill"
        case .aurora: "sparkles.rectangle.stack"
        }
    }

    var blurb: String {
        switch self {
        case .minimal: "Black and white, nothing extra"
        case .playful: "A soft colour for every tab"
        case .neon: "Electric colours that glow"
        case .glass: "Liquid Glass over your desktop"
        case .aurora: "Glass with soft colour light"
        }
    }

    func color(for tab: Tab) -> Color {
        let hue: (Double, Double, Double)
        switch tab {
        case .today: hue = (1.00, 0.80, 0.45)
        case .tasks: hue = (0.70, 0.64, 1.00)
        case .finance: hue = (0.35, 0.88, 0.55)
        case .habits: hue = (1.00, 0.70, 0.30)
        case .environments: hue = (0.40, 0.75, 1.00)
        case .shortcuts: hue = (0.95, 0.45, 0.70)
        case .system: hue = (0.55, 0.90, 0.80)
        case .calendar: hue = (1.00, 0.55, 0.50)
        case .claude: hue = (1.00, 0.62, 0.36)
        case .chat: hue = (0.40, 0.85, 0.65)
        case .weather: hue = (0.45, 0.75, 1.00)
        case .jira: hue = (0.42, 0.66, 1.00)
        case .gitlab: hue = (1.00, 0.50, 0.38)
        case .messages: hue = (1.00, 0.52, 0.72)
        case .clipboard: hue = (0.38, 0.86, 0.78)
        case .translate: hue = (0.35, 0.80, 0.95)
        case .tools: hue = (1.00, 0.82, 0.35)
        case .accounts: hue = (0.50, 0.88, 0.55)
        case .notes: hue = (0.98, 0.78, 0.55)
        case .media: hue = (0.80, 0.55, 1.00)
        case .settings: hue = (0.75, 0.75, 0.80)
        }
        switch self {
        case .minimal:
            return Color(white: 0.88)
        case .playful, .glass, .aurora:
            // Soft: pulled towards white.
            return Color(red: hue.0 * 0.8 + 0.2, green: hue.1 * 0.8 + 0.2, blue: hue.2 * 0.8 + 0.2)
        case .neon:
            // Electric: the strongest channel pushed up, the weakest down.
            let top = max(hue.0, hue.1, hue.2), low = min(hue.0, hue.1, hue.2)
            func push(_ v: Double) -> Double { v == top ? 1 : v == low ? v * 0.35 : v }
            return Color(red: push(hue.0), green: push(hue.1), blue: push(hue.2))
        }
    }
}

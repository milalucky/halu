import SwiftUI

/// Colour style (Settings → Appearance): Minimal is monochrome, Playful gives each tab its own soft
/// colour, Neon makes those colours electric and lets them glow.
enum Style: String, CaseIterable, Identifiable {
    case minimal = "Minimal", playful = "Playful", neon = "Neon"
    var id: String { rawValue }

    /// The style in use; read while drawing. AppModel keeps it current.
    static var current: Style = Style(rawValue: UserDefaults.standard.string(forKey: "style") ?? "") ?? .playful

    var glows: Bool { self == .neon }

    func color(for tab: Tab) -> Color {
        let hue: (Double, Double, Double)
        switch tab {
        case .tasks: hue = (0.70, 0.64, 1.00)
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
        case .playful:
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

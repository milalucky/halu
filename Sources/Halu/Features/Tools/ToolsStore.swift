import AppKit

/// State of the Tools tab, kept while the panel is closed.
@MainActor
final class ToolsStore: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case generate = "Test data", convert = "Decode", compare = "Compare", calculator = "Calculator", converter = "Converter", emoji = "Emoji", stocks = "Stocks", teleprompter = "Teleprompter"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .generate: "wand.and.stars"
            case .convert: "chevron.left.forwardslash.chevron.right"
            case .compare: "arrow.left.arrow.right.square"
            case .calculator: "plus.forwardslash.minus"
            case .converter: "arrow.triangle.2.circlepath"
            case .teleprompter: "text.alignleft"
            case .emoji: "face.smiling"
            case .stocks: "chart.line.uptrend.xyaxis"
            }
        }
    }

    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "tools.mode") == "Convert" ? "Decode" : UserDefaults.standard.string(forKey: "tools.mode") ?? "") ?? .generate {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "tools.mode") }
    }
    /// Your email, for "+alias" addresses.
    @Published var baseEmail = UserDefaults.standard.string(forKey: "tools.baseEmail") ?? "" {
        didSet {
            UserDefaults.standard.set(baseEmail, forKey: "tools.baseEmail")
            regenerate("Email alias")
        }
    }
    @Published private(set) var values: [String: String] = [:]
    @Published var input = ""
    /// Screen utilities next to the modes.
    enum Utility: String, CaseIterable, Identifiable {
        case color = "Colour picker", mirror = "Mirror", ruler = "Ruler"
        var id: String { rawValue }
        var icon: String { self == .color ? "eyedropper" : self == .mirror ? "web.camera" : "ruler" }
    }

    /// Sections turned off in Settings.
    @Published private(set) var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "tools.hidden") ?? [])

    var modes: [Mode] { Mode.allCases.filter { !hidden.contains($0.rawValue) } }
    func shows(_ utility: Utility) -> Bool { !hidden.contains(utility.rawValue) }

    func isShown(_ name: String) -> Bool { !hidden.contains(name) }

    func setShown(_ name: String, _ shown: Bool) {
        if shown { hidden.remove(name) } else { hidden.insert(name) }
        // Keep at least one mode.
        if modes.isEmpty { hidden.remove(Mode.generate.rawValue) }
        if !modes.contains(mode), let first = modes.first { mode = first }
        UserDefaults.standard.set(Array(hidden), forKey: "tools.hidden")
    }

    /// The camera mirror is open over the Tools tab.
    @Published var showingMirror = false
    @Published private(set) var copied: String?

    init() {
        TestData.generators.forEach { values[$0.title] = $0.make(baseEmail) }
    }

    func regenerate(_ title: String) {
        guard let generator = TestData.generators.first(where: { $0.title == title }) else { return }
        values[title] = generator.make(baseEmail)
    }

    /// Copies, then makes a fresh value for next time.
    func copy(_ title: String, value: String, refresh: Bool = true) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = title
        if refresh { regenerate(title) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copied == title { self?.copied = nil }
        }
    }

    func pasteInput() {
        input = NSPasteboard.general.string(forType: .string) ?? input
    }
}

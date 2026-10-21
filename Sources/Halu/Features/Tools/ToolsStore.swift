import AppKit

/// State of the Tools tab, kept while the panel is closed.
@MainActor
final class ToolsStore: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case generate = "Test data", convert = "Convert"
        var id: String { rawValue }
    }

    @Published var mode: Mode = .generate
    /// Your email, for "+alias" addresses.
    @Published var baseEmail = UserDefaults.standard.string(forKey: "tools.baseEmail") ?? "" {
        didSet {
            UserDefaults.standard.set(baseEmail, forKey: "tools.baseEmail")
            regenerate("Email alias")
        }
    }
    @Published private(set) var values: [String: String] = [:]
    @Published var input = ""
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

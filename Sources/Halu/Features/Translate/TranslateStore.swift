import AppKit

/// English ↔ Russian through Google Translate. The direction follows the script of the
/// input unless the user flips it.
@MainActor
final class TranslateStore: ObservableObject {
    enum Language: String {
        case en, ru

        var name: String { self == .en ? "English" : "Russian" }
        var other: Language { self == .en ? .ru : .en }
        var speechLocale: String { self == .en ? "en-US" : "ru-RU" }
    }

    @Published var input = "" {
        didSet {
            if input.isEmpty { manualSource = nil }
            schedule()
        }
    }
    @Published private(set) var output = ""
    @Published private(set) var isLoading = false
    @Published private(set) var problem: String?
    @Published private(set) var manualSource: Language?

    private var pending: Task<Void, Never>?

    var source: Language {
        if let manualSource { return manualSource }
        return input.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil ? .ru : .en
    }

    var target: Language { source.other }

    func swap() {
        manualSource = source.other
        if !output.isEmpty {
            let translated = output
            input = translated
        } else {
            schedule()
        }
    }

    func clear() {
        input = ""
        output = ""
        problem = nil
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    private func schedule() {
        pending?.cancel()
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            output = ""
            isLoading = false
            return
        }
        let from = source, to = target
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.isLoading = true
            let result = await Self.translate(text, from: from, to: to)
            guard !Task.isCancelled, let self else { return }
            self.isLoading = false
            switch result {
            case .success(let translated):
                self.output = translated
                self.problem = nil
            case .failure:
                self.problem = "Couldn't reach Google Translate. Check your connection."
            }
        }
    }

    private nonisolated static func translate(_ text: String, from: Language, to: Language) async -> Result<String, Error> {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: from.rawValue),
            URLQueryItem(name: "tl", value: to.rawValue),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        do {
            let (data, _) = try await URLSession.shared.data(from: components.url!)
            // Response: [[["translated", "source", …], …], …]
            guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let sentences = root.first as? [Any] else { throw URLError(.cannotParseResponse) }
            let joined = sentences.compactMap { ($0 as? [Any])?.first as? String }.joined()
            return .success(joined)
        } catch {
            return .failure(error)
        }
    }
}

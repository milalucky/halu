import AppKit
import Translation

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
            case .failure(let error):
                NSLog("Halu: translate failed: \(String(describing: error))")
                self.problem = "Translation failed: \(error.localizedDescription)"
            }
        }
    }

    enum TranslateError: LocalizedError {
        case http(Int)
        case unreadable
        case appleUnavailable

        var errorDescription: String? {
            switch self {
            case .http(let code): "Google Translate answered \(code)."
            case .unreadable: "Google Translate sent an unexpected answer."
            case .appleUnavailable: "Download English and Russian in System Settings → General → Language & Region → Translation Languages."
            }
        }
    }

    /// Google first (two public endpoints: one gets rate-limited now and then), then Apple's on-device
    /// translator, which needs both languages downloaded once.
    private static func translate(_ text: String, from: Language, to: Language) async -> Result<String, Error> {
        var lastError: Error = TranslateError.unreadable
        for endpoint in GoogleEndpoint.allCases {
            do {
                return .success(try await endpoint.translate(text, from: from, to: to))
            } catch {
                NSLog("Halu: \(endpoint) translate failed: \(String(describing: error))")
                lastError = error
            }
        }
        if #available(macOS 26.0, *) {
            do {
                let session = TranslationSession(installedSource: Locale.Language(identifier: from.rawValue),
                                                 target: Locale.Language(identifier: to.rawValue))
                return .success(try await session.translate(text).targetText)
            } catch {
                NSLog("Halu: Apple translate failed: \(String(describing: error))")
                lastError = TranslateError.appleUnavailable
            }
        }
        return .failure(lastError)
    }

    private enum GoogleEndpoint: CaseIterable {
        case extensionAPI, gtx

        func translate(_ text: String, from: Language, to: Language) async throws -> String {
            var components: URLComponents
            switch self {
            case .extensionAPI:
                components = URLComponents(string: "https://clients5.google.com/translate_a/t")!
                components.queryItems = [URLQueryItem(name: "client", value: "dict-chrome-ex")]
            case .gtx:
                components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
                components.queryItems = [URLQueryItem(name: "client", value: "gtx"), URLQueryItem(name: "dt", value: "t")]
            }
            components.queryItems! += [
                URLQueryItem(name: "sl", value: from.rawValue),
                URLQueryItem(name: "tl", value: to.rawValue),
                URLQueryItem(name: "q", value: text),
            ]
            let request = URLRequest(url: components.url!, timeoutInterval: 10)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { throw TranslateError.http(status) }
            let root = try JSONSerialization.jsonObject(with: data) as? [Any]
            switch self {
            case .extensionAPI:
                // ["translated"] or, with several segments, [["translated", "source language"], …]
                let parts = (root ?? []).compactMap { item -> String? in
                    (item as? String) ?? ((item as? [Any])?.first as? String)
                }
                guard !parts.isEmpty else { throw TranslateError.unreadable }
                return parts.joined()
            case .gtx:
                // [[["translated", "source", …], …], …]
                guard let sentences = root?.first as? [Any] else { throw TranslateError.unreadable }
                return sentences.compactMap { ($0 as? [Any])?.first as? String }.joined()
            }
        }
    }
}

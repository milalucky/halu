import AppKit
import SwiftUI

/// Every emoji macOS draws, with its Unicode name to search by.
enum EmojiCatalog {
    struct Emoji: Identifiable, Hashable {
        var id: String { char }
        let char: String
        let name: String
    }

    static let all: [Emoji] = {
        let ranges: [ClosedRange<UInt32>] = [0x1F600...0x1F64F, 0x1F90C...0x1F9FF, 0x1F300...0x1F5FF, 0x1F680...0x1F6FF,
                                              0x1FA70...0x1FAFF, 0x2600...0x27BF]
        return ranges.flatMap { $0 }.compactMap { value -> Emoji? in
            guard let scalar = Unicode.Scalar(value), scalar.properties.isEmojiPresentation else { return nil }
            let char = String(Character(scalar))
            let name = (char.applyingTransform(.toUnicodeName, reverse: false) ?? "")
                .replacingOccurrences(of: "\\N{", with: "").replacingOccurrences(of: "}", with: "").lowercased()
            return Emoji(char: char, name: name)
        }
    }()
}

/// Rates for the calculator and a stock watchlist, from free sources without keys:
/// open.er-api.com for currencies, Yahoo Finance's chart endpoint for stocks.
@MainActor
final class MarketStore: ObservableObject {
    struct Quote: Identifiable, Equatable {
        var id: String { symbol }
        var symbol: String
        var price: Double
        var previousClose: Double
        var currency: String
        var points: [Double]
        var change: Double { previousClose > 0 ? (price - previousClose) / previousClose * 100 : 0 }
    }

    @Published private(set) var rates: [String: Double] = [:]
    @Published private(set) var ratesDate: Date?
    @Published private(set) var quotes: [Quote] = []
    @Published var watchlist: [String] = UserDefaults.standard.stringArray(forKey: "stocks.watchlist") ?? ["AAPL", "NVDA", "TSLA", "BTC-USD"] {
        didSet {
            UserDefaults.standard.set(watchlist, forKey: "stocks.watchlist")
            loadQuotes()
        }
    }
    @Published var calcInput = ""
    @Published private(set) var calcHistory: [String] = UserDefaults.standard.stringArray(forKey: "calc.history") ?? []
    @Published var emojiQuery = ""
    @Published private(set) var recentEmoji: [String] = UserDefaults.standard.stringArray(forKey: "emoji.recent") ?? []

    private var lastQuotes: Date?

    func loadRates() {
        guard ratesDate.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true else { return }
        Task {
            guard let url = URL(string: "https://open.er-api.com/v6/latest/USD"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rates = json["rates"] as? [String: Double] else { return }
            self.rates = rates
            ratesDate = Date()
        }
    }

    /// Prices refresh at most every two minutes, and only while the Stocks view is open.
    func loadQuotes(force: Bool = false) {
        guard force || lastQuotes.map({ Date().timeIntervalSince($0) > 120 }) ?? true else { return }
        lastQuotes = Date()
        let symbols = watchlist
        Task {
            var loaded: [Quote] = []
            for symbol in symbols {
                if let quote = await Self.quote(symbol) { loaded.append(quote) }
            }
            quotes = loaded
        }
    }

    private static func quote(_ symbol: String) async -> Quote? {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=1d&interval=15m") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = ((json["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any], let price = meta["regularMarketPrice"] as? Double else { return nil }
        let closes = (((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first?["close"] as? [Any])?
            .compactMap { $0 as? Double } ?? []
        return Quote(symbol: meta["symbol"] as? String ?? symbol, price: price,
                     previousClose: meta["chartPreviousClose"] as? Double ?? price, currency: meta["currency"] as? String ?? "", points: closes)
    }

    func add(_ symbol: String) {
        let clean = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !clean.isEmpty, !watchlist.contains(clean) else { return }
        watchlist.append(clean)
        loadQuotes(force: true)
    }

    func remove(_ symbol: String) { watchlist.removeAll { $0 == symbol } }

    func remember(_ line: String) {
        calcHistory.removeAll { $0 == line }
        calcHistory.insert(line, at: 0)
        calcHistory = Array(calcHistory.prefix(12))
        UserDefaults.standard.set(calcHistory, forKey: "calc.history")
    }

    func copyEmoji(_ emoji: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(emoji, forType: .string)
        recentEmoji.removeAll { $0 == emoji }
        recentEmoji.insert(emoji, at: 0)
        recentEmoji = Array(recentEmoji.prefix(16))
        UserDefaults.standard.set(recentEmoji, forKey: "emoji.recent")
    }
}

// MARK: Views

/// Sums, units and currencies in one line; Return keeps the line in the history.
struct CalculatorView: View {
    @ObservedObject var market: MarketStore
    @State private var copied = false

    var body: some View {
        let answer = Calculator.evaluate(market.calcInput, rates: market.rates)
        VStack(alignment: .leading, spacing: 10) {
            InputField(placeholder: "2+2*3 · 15% of 200 · 10 km in mi · 100 usd in rub", icon: "function", text: $market.calcInput) {
                if answer != nil { market.remember(market.calcInput) }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(answer?.value ?? (market.calcInput.isEmpty ? "0" : "…"))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(answer == nil ? Theme.tertiary : Theme.primary)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.3), value: answer?.value)
                    .textSelection(.enabled)
                Spacer()
                if let answer {
                    PillButton(title: copied ? "Copied" : "Copy", icon: copied ? "checkmark" : "doc.on.doc", prominent: false) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer.value, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                }
            }
            if let answer { Text(answer.detail).font(Theme.caption(11.5, weight: .regular)).foregroundStyle(Theme.tertiary) }
            if let usd = market.rates["RUB"], let eur = market.rates["EUR"], let kzt = market.rates["KZT"] {
                HStack(spacing: 14) {
                    Rate(label: "USD", value: usd)
                    Rate(label: "EUR", value: usd / eur)
                    Rate(label: "100 KZT", value: usd / kzt * 100)
                    Spacer()
                    Text("₽ · open.er-api.com").font(Theme.caption(10, weight: .regular)).foregroundStyle(Theme.tertiary)
                }
            }
            if !market.calcHistory.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(market.calcHistory, id: \.self) { line in
                            HoverRow { _ in
                                HStack {
                                    Text(line).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
                                    Spacer()
                                    Text(Calculator.evaluate(line, rates: market.rates)?.value ?? "")
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.primary)
                                }
                            }
                            .onTapGesture { market.calcInput = line }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .onAppear(perform: market.loadRates)
    }

    private struct Rate: View {
        let label: String
        let value: Double
        var body: some View {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(Theme.tertiary)
                Text(Calculator.format(value, money: true)).foregroundStyle(Theme.primary).monospacedDigit()
            }
            .font(Theme.caption(11.5, weight: .semibold))
        }
    }
}

/// Search by name, click to copy; the ones you used come first.
struct EmojiView: View {
    @ObservedObject var market: MarketStore
    @State private var copied: String?

    private var results: [EmojiCatalog.Emoji] {
        let query = market.emojiQuery.lowercased().trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? EmojiCatalog.all : EmojiCatalog.all.filter { $0.name.contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InputField(placeholder: "Search emoji in English: heart, fire, party…", icon: "magnifyingglass", text: $market.emojiQuery)
            if market.emojiQuery.isEmpty && !market.recentEmoji.isEmpty {
                HStack(spacing: 2) {
                    ForEach(market.recentEmoji, id: \.self) { cell($0, name: "recent") }
                }
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 14), spacing: 2) {
                    ForEach(results) { cell($0.char, name: $0.name) }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func cell(_ char: String, name: String) -> some View {
        EmojiCell(char: char, copied: copied == char) {
            market.copyEmoji(char)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { copied = char }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if copied == char { copied = nil } }
        }
        .help(name)
    }

    private struct EmojiCell: View {
        let char: String
        let copied: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(char)
                    .font(.system(size: 22))
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.cardHover : .clear))
                    .scaleEffect(copied ? 1.35 : (hovering ? 1.12 : 1))
                    .overlay(alignment: .bottom) {
                        if copied { Text("Copied").font(Theme.caption(8, weight: .bold)).foregroundStyle(Theme.green).offset(y: 10) }
                    }
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
        }
    }
}

/// A watchlist with the day's line for each symbol.
struct StocksView: View {
    @ObservedObject var market: MarketStore
    @State private var newSymbol = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InputField(placeholder: "Add a symbol: AAPL, YNDX.ME, BTC-USD, EURRUB=X…", icon: "plus", text: $newSymbol) {
                market.add(newSymbol)
                newSymbol = ""
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(market.watchlist, id: \.self) { symbol in
                        if let quote = market.quotes.first(where: { $0.symbol.caseInsensitiveCompare(symbol) == .orderedSame }) {
                            QuoteRow(quote: quote) { market.remove(symbol) }
                        } else {
                            HStack {
                                Text(symbol).font(Theme.body(13, weight: .semibold)).foregroundStyle(Theme.secondary)
                                Spacer()
                                ProgressView().controlSize(.mini)
                                IconButton(icon: "xmark", help: "Remove", size: 9) { market.remove(symbol) }
                            }
                            .padding(.horizontal, 12).frame(height: 44)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            Text("Prices from Yahoo Finance, may be delayed.").font(Theme.caption(10, weight: .regular)).foregroundStyle(Theme.tertiary)
        }
        .onAppear { market.loadQuotes() }
    }

    private struct QuoteRow: View {
        let quote: MarketStore.Quote
        let onRemove: () -> Void
        @State private var hovering = false

        var body: some View {
            let up = quote.change >= 0
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(quote.symbol).font(Theme.body(13, weight: .bold)).foregroundStyle(Theme.primary)
                    Text(quote.currency).font(Theme.caption(10, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
                .frame(width: 90, alignment: .leading)
                Sparkline(points: quote.points, up: up).frame(height: 26)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Calculator.format(quote.price, money: true)).font(Theme.body(13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.primary)
                    Text(String(format: "%@%.2f%%", up ? "+" : "", quote.change))
                        .font(Theme.caption(10.5, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(up ? Theme.green.opacity(0.75) : Theme.red.opacity(0.8)))
                }
                .frame(width: 96, alignment: .trailing)
                if hovering { IconButton(icon: "xmark", help: "Remove", size: 9, action: onRemove) }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.cardHover : Theme.card))
            .onHover { hovering = $0 }
        }
    }

    private struct Sparkline: View {
        let points: [Double]
        let up: Bool
        @State private var drawn = false

        var body: some View {
            GeometryReader { geo in
                let low = points.min() ?? 0, high = points.max() ?? 1, span = max(high - low, 0.0001)
                Path { path in
                    for (index, value) in points.enumerated() {
                        let x = geo.size.width * CGFloat(index) / CGFloat(max(points.count - 1, 1))
                        let y = geo.size.height * (1 - CGFloat((value - low) / span))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(up ? Theme.green : Theme.red, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .animation(.easeOut(duration: 0.8), value: drawn)
            }
            .onAppear { drawn = true }
        }
    }
}

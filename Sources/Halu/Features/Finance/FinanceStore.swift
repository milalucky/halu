import AppKit
import HaluCore
import UniformTypeIdentifiers

/// Income and spending: quick entries, bank statements, categories that learn, monthly budget.
/// Everything lives in one JSON file (`money.json`) in Halu's folder, on this Mac.
@MainActor
final class FinanceStore: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case overview = "Overview", transactions = "Transactions", plan = "Plan", categories = "Categories"
        var id: String { rawValue }
    }

    @Published private(set) var book: MoneyBook
    @Published var mode: Mode = .overview
    /// The month on screen: any date inside it.
    @Published var month = Date()
    @Published var draft = ""
    @Published var draftIncome = false
    /// Category picked by hand for the entry being typed (nil: guess from the words).
    @Published var draftCategory: String?
    @Published var query = ""
    @Published private(set) var importNote: String?

    private let file = JSONFile<MoneyBook>("money.json")

    init() {
        book = file.load() ?? MoneyBook()
    }

    var currency: String { book.baseCurrency }

    /// Rates against the US dollar, from the Tools market data; used to count other currencies in roubles.
    var rates: () -> [String: Double] = { [:] }

    /// An amount in the base currency (as is, when the rate isn't known yet).
    func inBase(_ amount: Double, _ code: String) -> Double {
        guard code != currency else { return amount }
        let rates = rates()
        guard let from = rates[code], let to = rates[currency], from > 0 else { return amount }
        return amount / from * to
    }

    func inBase(_ transaction: MoneyTransaction) -> Double { inBase(transaction.amount, transaction.currency) }

    /// Categories offered for new entries of one kind.
    func choices(income: Bool) -> [MoneyCategory] {
        book.categories.filter { ($0.kind == .income) == income && !$0.hidden }
    }

    /// The categories used most for this kind, for one-click picking.
    func frequent(income: Bool, limit: Int = 6) -> [MoneyCategory] {
        var counts: [String: Int] = [:]
        for transaction in book.transactions.suffix(400) where transaction.isIncome == income { counts[transaction.categoryID, default: 0] += 1 }
        let ranked = choices(income: income).sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
        return Array(ranked.prefix(limit))
    }

    // MARK: Entering

    private static let currencyWords: [String: String] = [
        "$": "USD", "usd": "USD", "долл": "USD", "доллар": "USD", "€": "EUR", "eur": "EUR", "евро": "EUR",
        "₽": "RUB", "rub": "RUB", "руб": "RUB", "р": "RUB", "₸": "KZT", "kzt": "KZT", "тенге": "KZT",
        "£": "GBP", "gbp": "GBP", "¥": "CNY", "cny": "CNY", "юань": "CNY", "₺": "TRY", "try": "TRY", "aed": "AED", "дирхам": "AED",
    ]

    /// "350 кофе", "$100 salary", "+85000 зарплата", "1200 руб такси": amount, currency, note and category.
    var parsedDraft: (amount: Double, currency: String, note: String, category: String)? {
        var text = draft.trimmingCharacters(in: .whitespaces)
        var code = currency
        // A currency sign or word anywhere in the line.
        for (word, value) in Self.currencyWords.sorted(by: { $0.key.count > $1.key.count }) {
            let pattern = word.count == 1 && !word.first!.isLetter
                ? NSRegularExpression.escapedPattern(for: word)
                : #"(?<![\p{L}])"# + NSRegularExpression.escapedPattern(for: word) + #"\.?(?![\p{L}])"#
            if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                code = value
                text.replaceSubrange(range, with: " ")
                break
            }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard let match = text.range(of: #"^[+-]?\d[\d\s]*([.,]\d+)?"#, options: .regularExpression)
                ?? text.range(of: #"[+-]?\d[\d\s]*([.,]\d+)?$"#, options: .regularExpression),
              let amount = StatementParser.parseNumber(String(text[match])), amount != 0 else { return nil }
        let note = text.replacingCharacters(in: match, with: "").trimmingCharacters(in: .whitespaces)
        let income = isIncomeDraft
        return (abs(amount), code, note, draftCategory ?? book.guessCategory(for: note, income: income))
    }

    /// Income when the switch says so, the line starts with "+", or its words are an income's
    /// ("salary", "зарплата", "кэшбэк") and no spending category's.
    var isIncomeDraft: Bool {
        let text = draft.trimmingCharacters(in: .whitespaces)
        if draftIncome || text.hasPrefix("+") { return true }
        let words = text.replacingOccurrences(of: #"[\d.,$€₽₸£¥+-]"#, with: " ", options: .regularExpression)
        guard words.contains(where: \.isLetter) else { return false }
        return book.guessCategory(for: words, income: true) != "income-other" && book.guessCategory(for: words, income: false) == "other"
    }

    func addDraft() {
        guard let parsed = parsedDraft else { return }
        let income = isIncomeDraft
        book.transactions.append(MoneyTransaction(date: Date(), amount: parsed.amount, currency: parsed.currency, isIncome: income,
                                                  categoryID: parsed.category, note: parsed.note))
        if draftCategory != nil, !parsed.note.isEmpty { book.learn(parsed.note, for: parsed.category) }
        draft = ""
        draftCategory = nil
        save()
    }

    func delete(_ transaction: MoneyTransaction) {
        book.transactions.removeAll { $0.id == transaction.id }
        save()
    }

    /// Moves a transaction to another category and remembers the shop for next time.
    func recategorize(_ transaction: MoneyTransaction, to categoryID: String) {
        guard let index = book.transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        book.transactions[index].categoryID = categoryID
        let key = MoneyBook.merchantKey(transaction.note)
        book.learn(transaction.note, for: categoryID)
        // Same shop elsewhere in the book, still in the old category: move those too.
        for other in book.transactions.indices where other != index && book.transactions[other].categoryID == transaction.categoryID
            && MoneyBook.merchantKey(book.transactions[other].note) == key && !key.isEmpty {
            book.transactions[other].categoryID = categoryID
        }
        save()
    }

    func setBudget(_ value: Double?) {
        book.monthlyBudget = value.flatMap { $0 > 0 ? $0 : nil }
        save()
    }

    func setBudget(_ value: Double?, for categoryID: String) {
        guard let index = book.categories.firstIndex(where: { $0.id == categoryID }) else { return }
        book.categories[index].budget = value.flatMap { $0 > 0 ? $0 : nil }
        save()
    }

    // MARK: Categories

    func addCategory(income: Bool) -> String {
        let id = "custom-" + UUID().uuidString.prefix(8)
        book.categories.append(MoneyCategory(id: String(id), name: income ? "New income" : "New category", emoji: income ? "💰" : "🏷️",
                                             kind: income ? .income : .expense))
        save()
        return String(id)
    }

    func update(_ category: MoneyCategory) {
        guard let index = book.categories.firstIndex(where: { $0.id == category.id }) else { return }
        book.categories[index] = category
        save()
    }

    /// Deletes a category; its transactions and plan items move to Other (or Other income).
    func deleteCategory(_ id: String) {
        guard let category = book.category(id), !["other", "income-other"].contains(id) else { return }
        let fallback = category.kind == .income ? "income-other" : "other"
        for index in book.transactions.indices where book.transactions[index].categoryID == id { book.transactions[index].categoryID = fallback }
        for index in book.plan.indices where book.plan[index].categoryID == id { book.plan[index].categoryID = fallback }
        book.categories.removeAll { $0.id == id }
        save()
    }

    func usage(of id: String) -> Int { book.transactions.filter { $0.categoryID == id }.count }

    // MARK: Plan

    func addPlanItem(income: Bool) {
        book.plan.append(PlanItem(title: income ? "Salary" : "Rent", amount: 0, isIncome: income,
                                  categoryID: income ? "salary" : "home", day: nil))
        save()
    }

    func update(_ item: PlanItem) {
        guard let index = book.plan.firstIndex(where: { $0.id == item.id }) else { return }
        book.plan[index] = item
        save()
    }

    func deletePlanItem(_ item: PlanItem) {
        book.plan.removeAll { $0.id == item.id }
        save()
    }

    func setSavingsGoal(_ value: Double?) {
        book.savingsGoal = value.flatMap { $0 > 0 ? $0 : nil }
        save()
    }

    var plannedIncome: Double { book.plan.filter(\.isIncome).reduce(0) { $0 + $1.amount } }
    /// Regular payments plus the category limits not already covered by them.
    var plannedSpending: Double {
        let regular = book.plan.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
        return max(regular, book.monthlyBudget ?? 0)
    }

    /// Has a planned item happened this month? (A transaction in its category close to its amount.)
    func isDone(_ item: PlanItem) -> Bool {
        monthTransactions.contains { $0.isIncome == item.isIncome && $0.categoryID == item.categoryID
            && abs(inBase($0) - item.amount) <= max(item.amount * 0.15, 1) }
    }

    func shiftMonth(_ step: Int) {
        month = Calendar.current.date(byAdding: .month, value: step, to: month) ?? month
    }

    // MARK: The month in numbers

    var monthRange: Range<Date> {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? month
        return start..<end
    }

    var monthTransactions: [MoneyTransaction] {
        let range = monthRange
        return book.transactions.filter { range.contains($0.date) }.sorted { $0.date > $1.date }
    }

    var spent: Double { monthTransactions.filter { !$0.isIncome }.reduce(0) { $0 + inBase($1) } }
    var earned: Double { monthTransactions.filter(\.isIncome).reduce(0) { $0 + inBase($1) } }

    /// Spending per category this month, biggest first.
    var byCategory: [(category: MoneyCategory, total: Double)] {
        var totals: [String: Double] = [:]
        for transaction in monthTransactions where !transaction.isIncome { totals[transaction.categoryID, default: 0] += inBase(transaction) }
        return totals.compactMap { id, total in book.category(id).map { ($0, total) } }.sorted { $0.total > $1.total }
    }

    /// Spending per day of the month.
    var byDay: [Double] {
        let calendar = Calendar.current
        let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        var totals = Array(repeating: 0.0, count: days)
        for transaction in monthTransactions where !transaction.isIncome {
            let day = calendar.component(.day, from: transaction.date) - 1
            if totals.indices.contains(day) { totals[day] += inBase(transaction) }
        }
        return totals
    }

    var searchResults: [MoneyTransaction] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let list = query.isEmpty ? monthTransactions : book.transactions.sorted { $0.date > $1.date }
        guard !query.isEmpty else { return list }
        return list.filter { transaction in
            transaction.note.localizedCaseInsensitiveContains(query)
                || (book.category(transaction.categoryID)?.name.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    // MARK: Statements

    func chooseStatement() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText] + (UTType(filenameExtension: "xlsx").map { [$0] } ?? [])
        panel.allowsMultipleSelection = true
        panel.message = "Choose bank statements (CSV or Excel)"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        importStatements(panel.urls)
    }

    func importStatements(_ urls: [URL]) {
        importNote = "Reading…"
        DispatchQueue.global(qos: .userInitiated).async {
            let tables = urls.map { Self.readTable($0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.add(tables) }
            }
        }
    }

    private func add(_ tables: [[[String]]?]) {
        var added = 0, duplicates = 0, skipped = 0, unreadable = 0
        var known = Set(book.transactions.compactMap(\.fingerprint))
        for table in tables {
            guard let table else { unreadable += 1; continue }
            let result = StatementParser.parse(table)
            skipped += result.skipped
            for row in result.rows {
                let fingerprint = "\(Int(row.date.timeIntervalSince1970 / 60))|\(row.amount)|\(row.isIncome)|\(row.description.lowercased())"
                guard known.insert(fingerprint).inserted else { duplicates += 1; continue }
                var category = book.guessCategory(for: row.description, income: row.isIncome)
                // Nothing in our words: try the bank's own category name.
                if category == "other" || category == "income-other", let bank = row.bankCategory {
                    let guess = book.guessCategory(for: bank, income: row.isIncome)
                    if guess != category { category = guess }
                }
                book.transactions.append(MoneyTransaction(date: row.date, amount: row.amount, currency: row.currency, isIncome: row.isIncome,
                                                          categoryID: category, note: row.description, source: .imported, fingerprint: fingerprint))
                added += 1
            }
        }
        save()
        var parts = ["Added \(added) transaction\(added == 1 ? "" : "s")"]
        if duplicates > 0 { parts.append("\(duplicates) already here") }
        if unreadable > 0 { parts.append("\(unreadable) file\(unreadable == 1 ? "" : "s") not understood") }
        importNote = parts.joined(separator: " · ")
        if added > 0, let latest = book.transactions.filter({ $0.source == .imported }).map(\.date).max() { month = latest }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.importNote = nil }
    }

    /// CSV (UTF-8 or Windows-1251) or the first sheet of an Excel workbook, as rows of cells.
    private nonisolated static func readTable(_ url: URL) -> [[String]]? {
        if url.pathExtension.lowercased() == "xlsx" { return XLSXReader.read(url) }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) ?? String(decoding: data, as: UTF8.self)
        return StatementParser.csv(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
    }

    private func save() { file.save(book) }
}

/// Reads the first worksheet of an .xlsx file. An .xlsx is a zip of XML files; the system `unzip`
/// pulls out the two that matter (shared strings and the sheet).
enum XLSXReader {
    static func read(_ url: URL) -> [[String]]? {
        guard let sheet = unzip(url, "xl/worksheets/sheet1.xml") else { return nil }
        let strings = unzip(url, "xl/sharedStrings.xml").map(SharedStrings.parse) ?? []
        return SheetParser.parse(sheet, strings: strings)
    }

    private static func unzip(_ url: URL, _ member: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, member]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    private final class SharedStrings: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var inText = false

        static func parse(_ data: Data) -> [String] {
            let delegate = SharedStrings()
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            return delegate.strings
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "si" { current = "" }
            if name == "t" { inText = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "t" { inText = false }
            if name == "si" { strings.append(current) }
        }
    }

    private final class SheetParser: NSObject, XMLParserDelegate {
        var rows: [[String]] = []
        private let strings: [String]
        private var row: [Int: String] = [:]
        private var column = 0
        private var type = ""
        private var value = ""
        private var inValue = false

        init(strings: [String]) { self.strings = strings }

        static func parse(_ data: Data, strings: [String]) -> [[String]] {
            let delegate = SheetParser(strings: strings)
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            return delegate.rows
        }

        /// "C12" → 2.
        private static func columnIndex(_ reference: String) -> Int {
            reference.prefix { $0.isLetter }.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "row": row = [:]
            case "c":
                column = attributes["r"].map(Self.columnIndex) ?? (row.keys.max() ?? -1) + 1
                type = attributes["t"] ?? ""
                value = ""
            case "v", "t": inValue = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if inValue { value += string } }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t": inValue = false
            case "c":
                row[column] = type == "s" ? (Int(value).flatMap { strings.indices.contains($0) ? strings[$0] : nil } ?? "") : value
            case "row":
                let width = (row.keys.max() ?? -1) + 1
                let cells = (0..<width).map { row[$0] ?? "" }
                if cells.contains(where: { !$0.isEmpty }) { rows.append(cells) }
            default: break
            }
        }
    }
}

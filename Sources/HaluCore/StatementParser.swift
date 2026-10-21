import Foundation

/// Turns a bank statement table (rows of cells, from CSV or Excel) into transactions. It finds the
/// header row by the column names banks use (Russian and English), so it copes with preamble rows,
/// one signed amount column or separate debit/credit columns, and the bank's own categories when present.
public enum StatementParser {
    public struct Row: Equatable {
        public var date: Date
        public var amount: Double
        public var isIncome: Bool
        public var currency: String
        public var description: String
        /// The bank's category name, if the statement has one.
        public var bankCategory: String?
    }

    public struct Result: Equatable {
        public var rows: [Row]
        public var skipped: Int
    }

    private enum Column: CaseIterable { case date, amount, debit, credit, currency, description, category, status, type }

    private static let headers: [Column: [String]] = [
        .date: ["дата операции", "дата транзакции", "дата и время", "дата", "date", "transaction date", "posting date", "booking date"],
        .amount: ["сумма операции", "сумма платежа", "сумма в валюте счета", "сумма в валюте карты", "сумма", "amount", "sum", "value"],
        .debit: ["расход", "списание", "дебет", "debit", "withdrawal", "out"],
        .credit: ["приход", "зачисление", "поступление", "кредит", "credit", "deposit", "in"],
        .currency: ["валюта операции", "валюта", "currency"],
        .description: ["описание", "назначение платежа", "назначение", "детали", "контрагент", "получатель", "место операции",
                       "наименование", "description", "details", "merchant", "payee", "memo", "narrative"],
        .category: ["категория", "category"],
        .status: ["статус", "status"],
        .type: ["тип операции", "тип", "type"],
    ]

    public static func parse(_ table: [[String]]) -> Result {
        guard let (headerIndex, columns) = findHeader(table) else { return Result(rows: [], skipped: table.count) }
        var rows: [Row] = []
        var skipped = 0
        for cells in table.dropFirst(headerIndex + 1) {
            func cell(_ column: Column) -> String? {
                guard let index = columns[column], index < cells.count else { return nil }
                let value = cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            if let status = cell(.status)?.lowercased(),
               ["failed", "отклон", "отмен", "declined", "canceled", "cancelled"].contains(where: status.contains) {
                skipped += 1
                continue
            }
            guard let date = cell(.date).flatMap(parseDate) else { skipped += 1; continue }
            var signed: Double?
            if let amount = cell(.amount).flatMap(parseNumber) {
                signed = amount
                // Unsigned amounts with a type column: "Списание" is spending, "Пополнение" income.
                if amount > 0, let type = cell(.type)?.lowercased() {
                    if ["списан", "расход", "покупка", "оплата", "debit", "purchase", "payment"].contains(where: type.contains) { signed = -amount }
                }
            } else {
                let debit = cell(.debit).flatMap(parseNumber).map(abs) ?? 0
                let credit = cell(.credit).flatMap(parseNumber).map(abs) ?? 0
                if debit > 0 { signed = -debit } else if credit > 0 { signed = credit }
            }
            guard let value = signed, value != 0 else { skipped += 1; continue }
            let description = cell(.description) ?? cell(.category) ?? ""
            rows.append(Row(date: date, amount: abs(value), isIncome: value > 0,
                            currency: (cell(.currency) ?? "RUB").uppercased().replacingOccurrences(of: "RUR", with: "RUB"),
                            description: description, bankCategory: cell(.category)))
        }
        return Result(rows: rows, skipped: skipped)
    }

    /// The first row that names at least a date and an amount (or debit/credit) column.
    private static func findHeader(_ table: [[String]]) -> (Int, [Column: Int])? {
        for (index, row) in table.prefix(40).enumerated() {
            var found: [Column: Int] = [:]
            for (position, raw) in row.enumerated() {
                let name = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                // Exact names first, then names that start with a known one ("Сумма операции, руб").
                for column in Column.allCases where found[column] == nil {
                    let names = headers[column] ?? []
                    if names.contains(name) || names.contains(where: { name.hasPrefix($0 + " ") || name.hasPrefix($0 + ",") || name.hasPrefix($0 + "(") }) {
                        found[column] = position
                        break
                    }
                }
            }
            if found[.date] != nil, found[.amount] != nil || found[.debit] != nil || found[.credit] != nil {
                return (index, found)
            }
        }
        return nil
    }

    /// "1 234,56", "-1234.56", "1,234.56", "−350 ₽", "(350.00)".
    public static func parseNumber(_ raw: String) -> Double? {
        var text = raw.replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{202F}", with: "")
        var negative = false
        if text.hasPrefix("(") && text.hasSuffix(")") { negative = true; text = String(text.dropFirst().dropLast()) }
        text = text.filter { $0.isNumber || $0 == "," || $0 == "." || $0 == "-" || $0 == "+" }
        guard !text.isEmpty else { return nil }
        if text.contains(",") && text.contains(".") {
            // The later one is the decimal mark.
            if text.lastIndex(of: ",")! > text.lastIndex(of: ".")! {
                text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                text = text.replacingOccurrences(of: ",", with: "")
            }
        } else {
            text = text.replacingOccurrences(of: ",", with: ".")
        }
        guard let value = Double(text) else { return nil }
        return negative ? -abs(value) : value
    }

    private static let dateFormats = ["dd.MM.yyyy HH:mm:ss", "dd.MM.yyyy HH:mm", "dd.MM.yyyy", "dd.MM.yy", "yyyy-MM-dd HH:mm:ss",
                                      "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "dd/MM/yyyy", "MM/dd/yyyy", "d MMM yyyy"]

    public static func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        // Excel stores dates as days since 1899-12-30.
        if let serial = Double(text), serial > 20000, serial < 80000 {
            return Date(timeIntervalSince1970: (serial - 25569) * 86400 - Double(TimeZone.current.secondsFromGMT()))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Splits CSV text, guessing the delimiter (; , or tab) from the first lines.
    public static func csv(_ text: String) -> [[String]] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let sample = lines.prefix(4000)
        let delimiter: Character = [";", "\t", ","].max { a, b in sample.filter { $0 == a }.count < sample.filter { $0 == b }.count } ?? ";"
        var table: [[String]] = []
        var row: [String] = [], cell = "", quoted = false
        var iterator = lines.makeIterator()
        var pending: Character? = nil
        while let char = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { cell.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { cell.append(char) }
            } else if char == "\"" {
                quoted = true
            } else if char == delimiter {
                row.append(cell); cell = ""
            } else if char == "\n" {
                row.append(cell); cell = ""
                if row.contains(where: { !$0.isEmpty }) { table.append(row) }
                row = []
            } else {
                cell.append(char)
            }
        }
        row.append(cell)
        if row.contains(where: { !$0.isEmpty }) { table.append(row) }
        return table
    }
}

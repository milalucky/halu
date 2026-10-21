import Foundation

/// Reads accounts out of text people already keep them in:
/// - Markdown lists: `- **Service:** …`, `- **Login:** \`…\``, `- **Password:** …`, `- **Notes:** …` per account;
/// - Markdown tables: `| Service | Login | Password | Notes |`;
/// - CSV or tab-separated rows, with or without a header, in that column order.
enum AccountImport {
    struct Row: Equatable {
        var service = "", login = "", password = "", notes = ""
    }

    static func parse(_ text: String) -> [Row] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let labelled = parseLabelled(lines)
        return labelled.isEmpty ? parseTable(lines) : labelled
    }

    // MARK: Labelled lists

    private static let labels: [String: WritableKeyPath<Row, String>] = [
        "service": \.service, "сервис": \.service, "site": \.service, "server": \.service,
        "login": \.login, "логин": \.login, "username": \.login, "user": \.login, "email": \.login,
        "password": \.password, "пароль": \.password,
        "notes": \.notes, "note": \.notes, "заметки": \.notes, "comment": \.notes,
    ]

    private static func parseLabelled(_ lines: [String]) -> [Row] {
        var rows: [Row] = []
        var current: Row?
        func flush() {
            if let row = current, !row.login.isEmpty { rows.append(row) }
            current = nil
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // A new heading starts a new account.
            if line.hasPrefix("#") { flush(); continue }
            guard let (label, value) = labelledValue(line), let path = labels[label] else { continue }
            if path == \Row.service, let row = current, !row.service.isEmpty { flush() }
            if current == nil { current = Row() }
            current![keyPath: path] = value
        }
        flush()
        return rows
    }

    /// `- **Login:** \`value\`` → ("login", "value").
    private static func labelledValue(_ line: String) -> (String, String)? {
        var text = line
        for prefix in ["- ", "* ", "• "] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let label = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard labels[label] != nil else { return nil }
        return (label, unquote(String(text[text.index(after: colon)...])))
    }

    /// Strips code ticks around a value but keeps everything inside, symbols included.
    private static func unquote(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("`"), value.hasSuffix("`") { value = String(value.dropFirst().dropLast()) }
        return value
    }

    // MARK: Tables

    private static func parseTable(_ lines: [String]) -> [Row] {
        var rows: [Row] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var cells: [String]
            if line.hasPrefix("|") {
                cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
            } else if line.contains("\t") {
                cells = line.components(separatedBy: "\t")
            } else {
                cells = csv(line)
            }
            cells = cells.map { unquote($0) }
            // Header and Markdown separator rows.
            if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
            if labels[cells.count > 1 ? cells[1].lowercased() : ""] == \Row.login { continue }
            guard cells.count >= 3, !cells[0].isEmpty, !cells[1].isEmpty else { continue }
            rows.append(Row(service: cells[0], login: cells[1], password: cells[2],
                            notes: cells.count > 3 ? cells[3...].joined(separator: " ").trimmingCharacters(in: .whitespaces) : ""))
        }
        return rows
    }

    /// One CSV line, quotes and doubled quotes included.
    private static func csv(_ line: String) -> [String] {
        var cells: [String] = [], cell = "", quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "\"" {
                let next = line.index(after: index)
                if quoted, next < line.endIndex, line[next] == "\"" {
                    cell.append("\"")
                    index = next
                } else {
                    quoted.toggle()
                }
            } else if char == ",", !quoted {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(char)
            }
            index = line.index(after: index)
        }
        cells.append(cell)
        return cells
    }
}

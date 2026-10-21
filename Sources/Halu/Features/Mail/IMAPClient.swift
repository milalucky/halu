import Foundation
import Network

/// The few IMAP commands Halu needs, read-only: log in, EXAMINE the inbox, find unread mail from the last
/// days and fetch its headers with BODY.PEEK, so nothing is ever marked as read.
final class IMAPClient: @unchecked Sendable {
    struct Envelope: Sendable {
        var uid: Int
        var from: String
        var subject: String
        var date: Date
        var messageID: String?
    }

    enum Failure: LocalizedError {
        case connection(String)
        case rejected(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .connection(let message): "Couldn't reach the mail server: \(message)"
            case .rejected(let message): message.isEmpty ? "The mail server refused the login." : message
            case .timeout: "The mail server didn't answer in time."
            }
        }
    }

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "halu.imap")
    private var connection: NWConnection?
    private var buffer = Data()
    private var counter = 0

    init(host: String, port: UInt16 = 993) {
        self.host = host
        self.port = port
    }

    /// Unread messages in INBOX from the last `days`, newest first, at most `limit`.
    func unread(user: String, password: String, days: Int = 7, limit: Int = 30) async throws -> [Envelope] {
        try await open()
        defer { close() }
        _ = try await readUntil { $0.contains("\r\n") } // greeting
        let login = try await command("LOGIN \(quote(user)) \(quote(password))")
        guard login.ok else { throw Failure.rejected(login.message) }
        _ = try await command("EXAMINE INBOX")

        let since = Self.searchDate.string(from: Date().addingTimeInterval(-Double(days) * 86400))
        let search = try await command("UID SEARCH UNSEEN SINCE \(since)")
        let uids = search.text
            .components(separatedBy: "\r\n")
            .first { $0.hasPrefix("* SEARCH") }?
            .split(separator: " ").dropFirst(2).compactMap { Int($0) } ?? []
        let wanted = Array(uids.sorted().suffix(limit))
        guard !wanted.isEmpty else {
            _ = try? await command("LOGOUT")
            return []
        }
        let set = wanted.map(String.init).joined(separator: ",")
        let fetch = try await command("UID FETCH \(set) (UID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)])")
        _ = try? await command("LOGOUT")
        return Self.parseFetch(fetch.text).sorted { $0.date > $1.date }
    }

    // MARK: Connection

    private func open() async throws {
        let tls = NWProtocolTLS.Options()
        let parameters = NWParameters(tls: tls)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        self.connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The handler runs on `queue` only, so the flag needs no lock.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            connection.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    once.done = true
                    continuation.resume(throwing: Failure.connection(error.localizedDescription))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func close() {
        connection?.cancel()
        connection = nil
    }

    private func command(_ text: String) async throws -> (ok: Bool, message: String, text: String) {
        counter += 1
        let tag = "H\(counter)"
        try await send("\(tag) \(text)\r\n")
        let response = try await readUntil { data in
            // Done when a line starts with our tag.
            data.hasPrefix("\(tag) ") || data.contains("\r\n\(tag) ")
        }
        let lines = response.components(separatedBy: "\r\n")
        let status = lines.last { $0.hasPrefix("\(tag) ") } ?? ""
        let ok = status.hasPrefix("\(tag) OK")
        let message = status.split(separator: " ", maxSplits: 2).dropFirst(2).first.map(String.init) ?? ""
        return (ok, message, response)
    }

    private func send(_ text: String) async throws {
        guard let connection else { throw Failure.connection("not connected") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: Failure.connection(error.localizedDescription)) } else { continuation.resume() }
            })
        }
    }

    /// Reads until `done` holds for everything received so far, then hands that text back and clears the buffer.
    private func readUntil(_ done: @escaping (String) -> Bool) async throws -> String {
        let deadline = Date().addingTimeInterval(20)
        while true {
            let text = String(decoding: buffer, as: UTF8.self)
            if done(text), text.hasSuffix("\r\n") {
                buffer.removeAll()
                return text
            }
            guard Date() < deadline else { throw Failure.timeout }
            let chunk = try await receive()
            buffer.append(chunk)
        }
    }

    private func receive() async throws -> Data {
        guard let connection else { throw Failure.connection("not connected") }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: Failure.connection(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: Failure.connection("closed"))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Parsing

    private static let searchDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy"
        return formatter
    }()

    private static let headerDates: [DateFormatter] = ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"].map {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = $0
        return formatter
    }

    static func parseFetch(_ text: String) -> [Envelope] {
        // Each message starts with "* <n> FETCH (UID <uid> BODY[...] {size}" followed by its header block.
        let parts = text.components(separatedBy: "\r\n* ").map { $0.hasPrefix("* ") ? String($0.dropFirst(2)) : $0 }
        return parts.compactMap { part -> Envelope? in
            guard part.contains("FETCH"), let uidRange = part.range(of: #"UID (\d+)"#, options: .regularExpression) else { return nil }
            let uid = Int(part[uidRange].split(separator: " ")[1]) ?? 0
            let headers = unfold(part)
            let from = decode(header("From", in: headers))
            let name = from.components(separatedBy: "<").first?.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) ?? from
            let rawDate = header("Date", in: headers).replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
            let date = headerDates.lazy.compactMap { $0.date(from: rawDate) }.first ?? Date()
            let id = header("Message-ID", in: headers).trimmingCharacters(in: CharacterSet(charactersIn: " <>"))
            return Envelope(uid: uid, from: name.isEmpty ? from : name, subject: decode(header("Subject", in: headers)),
                            date: date, messageID: id.isEmpty ? nil : id)
        }
    }

    /// Joins folded header lines (continuations start with whitespace).
    private static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for line in text.components(separatedBy: "\r\n") {
            if let first = line.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(line)
            }
        }
        return lines
    }

    private static func header(_ name: String, in lines: [String]) -> String {
        let prefix = name.lowercased() + ":"
        guard let line = lines.first(where: { $0.lowercased().hasPrefix(prefix) }) else { return "" }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Decodes RFC 2047 words such as =?UTF-8?B?...?= and =?utf-8?Q?...?=.
    static func decode(_ text: String) -> String {
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var last = text.startIndex
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let range = Range(match.range, in: text),
                  let charsetRange = Range(match.range(at: 1), in: text),
                  let kindRange = Range(match.range(at: 2), in: text),
                  let bodyRange = Range(match.range(at: 3), in: text) else { continue }
            let between = String(text[last..<range.lowerBound])
            // Whitespace between two encoded words is dropped.
            if !(between.trimmingCharacters(in: .whitespaces).isEmpty && !result.isEmpty) { result += between }
            let charset = String(text[charsetRange]).lowercased()
            let koi8 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)))
            let encoding: String.Encoding = charset.contains("1251") ? .windowsCP1251 : (charset.contains("koi8") ? koi8 : .utf8)
            let body = String(text[bodyRange])
            var data: Data?
            if text[kindRange].uppercased() == "B" {
                var padded = body
                while padded.count % 4 != 0 { padded += "=" }
                data = Data(base64Encoded: padded)
            } else {
                var bytes: [UInt8] = []
                var index = body.startIndex
                while index < body.endIndex {
                    let char = body[index]
                    if char == "_" {
                        bytes.append(0x20)
                    } else if char == "=", let end = body.index(index, offsetBy: 3, limitedBy: body.endIndex),
                              let byte = UInt8(body[body.index(after: index)..<end], radix: 16) {
                        bytes.append(byte)
                        index = body.index(index, offsetBy: 2)
                    } else {
                        bytes.append(contentsOf: Array(String(char).utf8))
                    }
                    index = body.index(after: index)
                }
                data = Data(bytes)
            }
            result += data.flatMap { String(data: $0, encoding: encoding) } ?? body
            last = range.upperBound
        }
        result += text[last...]
        return result
    }
}

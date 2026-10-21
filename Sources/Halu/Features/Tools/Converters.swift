import CryptoKit
import Foundation

/// Everything a pasted value can be read as: decoded Base64, URL encoding, a JWT, a timestamp,
/// formatted JSON, hashes. Only what fits the input is shown.
enum Converters {
    struct Result: Identifiable {
        var id: String { title }
        let title: String
        let value: String
    }

    static func all(_ raw: String) -> [Result] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var results: [Result] = []
        if let jwt = jwt(text) { results.append(Result(title: "JWT", value: jwt)) }
        if let json = prettyJSON(text) {
            results.append(Result(title: "JSON formatted", value: json.pretty))
            results.append(Result(title: "JSON minified", value: json.minified))
        }
        if let date = timestamp(text) { results.append(Result(title: "Timestamp → date", value: date)) }
        if let seconds = dateToTimestamp(text) { results.append(Result(title: "Date → timestamp", value: seconds)) }
        if let decoded = base64Decoded(text) { results.append(Result(title: "Base64 decoded", value: decoded)) }
        if let decoded = text.removingPercentEncoding, decoded != text { results.append(Result(title: "URL decoded", value: decoded)) }
        results.append(Result(title: "Base64 encoded", value: Data(text.utf8).base64EncodedString()))
        if let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed), encoded != text {
            results.append(Result(title: "URL encoded", value: encoded))
        }
        results.append(Result(title: "Length", value: "\(raw.count) characters · \(raw.split(whereSeparator: \.isWhitespace).count) words · \(raw.components(separatedBy: "\n").count) lines · \(raw.utf8.count) bytes"))
        results.append(Result(title: "SHA-256", value: hex(SHA256.hash(data: Data(raw.utf8)))))
        results.append(Result(title: "MD5", value: hex(Insecure.MD5.hash(data: Data(raw.utf8)))))
        return results
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func prettyJSON(_ text: String) -> (pretty: String, minified: String)? {
        guard text.first == "{" || text.first == "[",
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let minified = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return (String(decoding: pretty, as: UTF8.self), String(decoding: minified, as: UTF8.self))
    }

    private static func base64Data(_ text: String) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return Data(base64Encoded: value)
    }

    /// Only when it decodes to readable text.
    private static func base64Decoded(_ text: String) -> String? {
        guard text.count >= 4, !text.contains(" "), let data = base64Data(text),
              let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty,
              decoded.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }) else { return nil }
        return decoded
    }

    /// Header and payload, with `exp` / `iat` / `nbf` shown as dates. The signature isn't checked.
    private static func jwt(_ text: String) -> String? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let header = base64Data(String(parts[0])), let payload = base64Data(String(parts[1])),
              let headerJSON = prettyJSON(String(decoding: header, as: UTF8.self)),
              let payloadJSON = prettyJSON(String(decoding: payload, as: UTF8.self)) else { return nil }
        var text = "Header\n\(headerJSON.pretty)\n\nPayload\n\(payloadJSON.pretty)"
        if let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            let dates = ["exp", "iat", "nbf"].compactMap { key in (claims[key] as? Double).map { "\(key): \(format(Date(timeIntervalSince1970: $0)))" } }
            if !dates.isEmpty { text += "\n\n" + dates.joined(separator: "\n") }
            if let exp = claims["exp"] as? Double { text += Date(timeIntervalSince1970: exp) < Date() ? "\nExpired" : "\nValid until \(format(Date(timeIntervalSince1970: exp)))" }
        }
        return text
    }

    /// Seconds or milliseconds since 1970, in a sensible range.
    private static func timestamp(_ text: String) -> String? {
        guard let number = Double(text), number > 0 else { return nil }
        let seconds = number > 1e11 ? number / 1000 : number
        guard seconds > 946_684_800, seconds < 4_102_444_800 else { return nil } // 2000…2100
        let date = Date(timeIntervalSince1970: seconds)
        return "\(format(date))\nUTC \(ISO8601DateFormatter().string(from: date))"
    }

    private static func dateToTimestamp(_ text: String) -> String? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        guard let date = iso.date(from: text) ?? plain.date(from: text) ?? day.date(from: text) else { return nil }
        let seconds = Int(date.timeIntervalSince1970)
        return "\(seconds)\n\(seconds * 1000) ms"
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

private extension CharacterSet {
    /// Like `urlQueryAllowed` but also escapes &, =, + and ? so the value is safe inside a query.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?/")
        return set
    }()
}

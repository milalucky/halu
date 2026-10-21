import Foundation

/// Values testers keep typing by hand, made fresh on every click.
enum TestData {
    struct Generator: Identifiable {
        var id: String { title }
        let title: String
        let make: (_ baseEmail: String) -> String
    }

    static let generators: [Generator] = [
        Generator(title: "Email alias") { base in alias(base) },
        Generator(title: "UUID") { _ in UUID().uuidString.lowercased() },
        Generator(title: "Name") { _ in "\(firstNames.randomElement()!) \(lastNames.randomElement()!)" },
        Generator(title: "Phone") { _ in "+1 555 \(digits(3)) \(digits(4))" },
        Generator(title: "Password") { _ in password(16) },
        Generator(title: "Number") { _ in String(Int.random(in: 1...99_999)) },
        Generator(title: "Date") { _ in ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double.random(in: -3e7...3e7))) },
        Generator(title: "Timestamp") { _ in String(Int(Date().timeIntervalSince1970)) },
        Generator(title: "Sentence") { _ in sentence() },
        Generator(title: "256 characters") { _ in long(256) },
        Generator(title: "1000 characters") { _ in long(1000) },
        Generator(title: "Unicode") { _ in ["Ünïcödé ñ ß 🚀", "Привет, мир", "مرحبا بالعالم", "日本語のテキスト", "Zalgo z̷̢a̶l̸g̵o"].randomElement()! },
        Generator(title: "HTML injection") { _ in ["<script>alert(1)</script>", "<img src=x onerror=alert(1)>", "\"><b>bold</b>"].randomElement()! },
        Generator(title: "SQL injection") { _ in ["' OR 1=1 --", "'; DROP TABLE users; --", "\" OR \"\"=\""].randomElement()! },
        Generator(title: "Spaces") { _ in ["  leading", "trailing  ", "   ", "tab\there"].randomElement()! },
    ]

    /// "me@company.com" → "me+qa7f3k@company.com"; without a base, a made-up address.
    static func alias(_ base: String) -> String {
        let tag = "qa" + random(4, from: "abcdefghijkmnpqrstuvwxyz23456789")
        let parts = base.trimmingCharacters(in: .whitespaces).split(separator: "@")
        guard parts.count == 2 else { return "test+\(tag)@example.com" }
        let user = parts[0].split(separator: "+").first ?? parts[0]
        return "\(user)+\(tag)@\(parts[1])"
    }

    static func password(_ length: Int) -> String {
        let sets = ["ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnpqrstuvwxyz", "23456789", "!@#$%^&*-_=+"]
        var chars = sets.map { random(1, from: $0) }.joined()
        chars += random(length - chars.count, from: sets.joined())
        return String(chars.shuffled())
    }

    private static func random(_ count: Int, from alphabet: String) -> String {
        let letters = Array(alphabet)
        return String((0..<max(0, count)).map { _ in letters.randomElement()! })
    }

    private static func digits(_ count: Int) -> String { random(count, from: "0123456789") }

    private static let firstNames = ["Anna", "Ivan", "Olga", "Max", "Elena", "John", "Maria", "Alex", "Sofia", "Daniel", "Nina", "Leo"]
    private static let lastNames = ["Smith", "Petrova", "Ivanov", "Johnson", "Garcia", "Kim", "Novak", "Brown", "Sokolova", "Miller"]
    private static let words = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua".split(separator: " ")

    private static func sentence() -> String {
        let text = (0..<Int.random(in: 6...12)).map { _ in String(words.randomElement()!) }.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    private static func long(_ count: Int) -> String {
        var text = ""
        while text.count < count { text += sentence() + " " }
        return String(text.prefix(count))
    }
}

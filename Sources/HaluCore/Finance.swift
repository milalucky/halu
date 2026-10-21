import Foundation

// Money: income and spending, categories and budgets. Plain Codable values with no UI or platform code,
// so the iPhone and Watch apps can share them and a sync layer can be added underneath later.

public struct MoneyCategory: Codable, Identifiable, Equatable, Hashable {
    public enum Kind: String, Codable { case expense, income }

    public var id: String
    public var name: String
    public var emoji: String
    public var kind: Kind
    /// Monthly limit in the base currency; nil means no limit.
    public var budget: Double?
    /// Lower-case words that put a transaction here when they appear in its description.
    public var keywords: [String]

    public init(id: String, name: String, emoji: String, kind: Kind, budget: Double? = nil, keywords: [String] = []) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.kind = kind
        self.budget = budget
        self.keywords = keywords
    }
}

public struct MoneyTransaction: Codable, Identifiable, Equatable {
    public enum Source: String, Codable { case manual, imported }

    public var id: UUID
    public var date: Date
    /// Always positive; `isIncome` says which way it went.
    public var amount: Double
    public var currency: String
    public var isIncome: Bool
    public var categoryID: String
    public var note: String
    public var source: Source
    /// For imported rows: a fingerprint of date, amount and description, so a statement loaded twice adds nothing.
    public var fingerprint: String?

    public init(id: UUID = UUID(), date: Date, amount: Double, currency: String, isIncome: Bool, categoryID: String,
                note: String, source: Source = .manual, fingerprint: String? = nil) {
        self.id = id
        self.date = date
        self.amount = amount
        self.currency = currency
        self.isIncome = isIncome
        self.categoryID = categoryID
        self.note = note
        self.source = source
        self.fingerprint = fingerprint
    }
}

public struct MoneyBook: Codable, Equatable {
    public var transactions: [MoneyTransaction]
    public var categories: [MoneyCategory]
    /// Monthly spending budget in the base currency; nil means none.
    public var monthlyBudget: Double?
    public var baseCurrency: String

    public init(transactions: [MoneyTransaction] = [], categories: [MoneyCategory] = MoneyBook.defaultCategories,
                monthlyBudget: Double? = nil, baseCurrency: String = "RUB") {
        self.transactions = transactions
        self.categories = categories
        self.monthlyBudget = monthlyBudget
        self.baseCurrency = baseCurrency
    }

    public func category(_ id: String) -> MoneyCategory? { categories.first { $0.id == id } }

    /// The category whose keywords appear in `text`, the longest match winning ("yandex taxi" over "yandex").
    public func guessCategory(for text: String, income: Bool) -> String {
        let haystack = text.lowercased()
        var best: (id: String, length: Int)?
        for category in categories where (category.kind == .income) == income {
            for word in category.keywords where !word.isEmpty && haystack.contains(word) {
                if word.count > (best?.length ?? 0) { best = (category.id, word.count) }
            }
        }
        return best?.id ?? (income ? "income-other" : "other")
    }

    /// Teaches a category a word from a description, so similar ones land there next time.
    public mutating func learn(_ description: String, for categoryID: String) {
        let key = MoneyBook.merchantKey(description)
        guard key.count >= 3, let index = categories.firstIndex(where: { $0.id == categoryID }) else { return }
        for other in categories.indices where other != index { categories[other].keywords.removeAll { $0 == key } }
        if !categories[index].keywords.contains(key) { categories[index].keywords.append(key) }
    }

    /// The part of a bank description that names the shop: lower-cased, digits and card masks dropped,
    /// its first word (or two when the first is short).
    public static func merchantKey(_ description: String) -> String {
        let cleaned: String = description.lowercased()
            .replacingOccurrences(of: #"[\d*#№/\\.,:;()\[\]"'«»-]+"#, with: " ", options: .regularExpression)
        let words: [Substring] = cleaned.split(separator: Character(" ")).filter { $0.count > 1 }
        // A distinctive first word names the shop on its own ("пятёрочка"); short ones need the next word.
        guard let first = words.first else { return "" }
        return first.count >= 5 ? String(first) : words.prefix(2).joined(separator: " ")
    }

    public static let defaultCategories: [MoneyCategory] = [
        MoneyCategory(id: "groceries", name: "Groceries", emoji: "🛒", kind: .expense, keywords: [
            "пятерочка", "пятёрочка", "перекресток", "перекрёсток", "магнит", "вкусвилл", "лента", "ашан", "auchan", "дикси",
            "spar", "спар", "metro", "окей", "о'кей", "globus", "глобус", "самокат", "samokat", "лавка", "азбука вкуса",
            "fix price", "светофор", "верный", "магнолия", "продукты", "supermarket", "grocery", "market", "магазин у дома", "супермаркет"]),
        MoneyCategory(id: "cafes", name: "Cafés & food", emoji: "☕️", kind: .expense, keywords: [
            "кафе", "cafe", "coffee", "кофе", "ресторан", "restaurant", "starbucks", "шоколадница", "додо", "dodo", "kfc",
            "ростикс", "вкусно и точка", "бургер", "burger", "макдоналдс", "теремок", "суши", "sushi", "pizza", "пицца",
            "delivery club", "яндекс еда", "yandex eda", "eda.yandex", "кулинария", "столовая", "bar ", "бар ", "bakery", "пекарня", "фастфуд", "рестора"]),
        MoneyCategory(id: "transport", name: "Transport", emoji: "🚕", kind: .expense, keywords: [
            "такси", "taxi", "uber", "яндекс go", "yandex go", "ситимобил", "метро", "metro moscow", "транспорт", "тройка",
            "мцд", "автобус", "аэроэкспресс", "ржд", "rzd", "азс", "лукойл", "газпромнефть", "роснефть", "shell", "парковка",
            "parking", "каршеринг", "делимобиль", "belkacar", "whoosh", "самокаты", "топливо", "автоуслуг"]),
        MoneyCategory(id: "shopping", name: "Shopping", emoji: "🛍️", kind: .expense, keywords: [
            "wildberries", "вайлдберриз", "ozon", "озон", "яндекс маркет", "market.yandex", "aliexpress", "lamoda", "ламода",
            "zara", "uniqlo", "h&m", "ikea", "икеа", "леруа", "lerua", "dns", "м.видео", "мвидео", "эльдорадо", "detsky mir",
            "детский мир", "спортмастер", "золотое яблоко", "летуаль", "рив гош", "одежд", "маркетплейс", "электроник", "ремонт"]),
        MoneyCategory(id: "health", name: "Health", emoji: "💊", kind: .expense, keywords: [
            "аптека", "apteka", "pharmacy", "здравсити", "ригла", "36.6", "клиника", "clinic", "стоматолог", "медси",
            "инвитро", "invitro", "гемотест", "доктор", "лаборатория", "аптек", "медицин"]),
        MoneyCategory(id: "home", name: "Home & utilities", emoji: "🏠", kind: .expense, keywords: [
            "жкх", "жку", "квартплата", "коммунал", "мосэнерго", "мосэнергосбыт", "электроэнерг", "водоканал", "газ", "аренда",
            "rent", "управляющая компания", "ук ", "жкх"]),
        MoneyCategory(id: "subscriptions", name: "Subscriptions", emoji: "🔁", kind: .expense, keywords: [
            "apple.com", "itunes", "icloud", "spotify", "netflix", "youtube", "google", "яндекс плюс", "yandex plus", "кинопоиск",
            "okko", "ivi", "openai", "chatgpt", "anthropic", "claude", "notion", "figma", "github", "adobe", "patreon", "boosty", "цифровые товары", "подписк"]),
        MoneyCategory(id: "phone", name: "Phone & internet", emoji: "📱", kind: .expense, keywords: [
            "мтс", "mts", "билайн", "beeline", "мегафон", "megafon", "теле2", "tele2", "t2 ", "ростелеком", "rostelecom",
            "домру", "дом.ру", "интернет", "yota", "мобильная связь", "связь"]),
        MoneyCategory(id: "fun", name: "Entertainment", emoji: "🎬", kind: .expense, keywords: [
            "кино", "cinema", "театр", "концерт", "билет", "ticket", "яндекс афиша", "afisha", "steam", "playstation", "xbox",
            "nintendo", "боулинг", "музей", "квест", "развлечен"]),
        MoneyCategory(id: "travel", name: "Travel", emoji: "✈️", kind: .expense, keywords: [
            "аэрофлот", "aeroflot", "s7", "победа", "pobeda", "utair", "hotel", "отель", "booking", "airbnb", "островок",
            "ostrovok", "туту", "tutu", "авиабилет", "aviasales", "суточно", "ж/д", "отел", "путешеств"]),
        MoneyCategory(id: "beauty", name: "Beauty", emoji: "💅", kind: .expense, keywords: [
            "салон", "барбершоп", "barber", "маникюр", "косметолог", "beauty", "spa", "спа", "красот"]),
        MoneyCategory(id: "education", name: "Education", emoji: "📚", kind: .expense, keywords: [
            "курс", "course", "skillbox", "нетология", "яндекс практикум", "practicum", "stepik", "coursera", "udemy", "skyeng",
            "книга", "литрес", "litres", "образован", "книг"]),
        MoneyCategory(id: "gifts", name: "Gifts", emoji: "🎁", kind: .expense, keywords: ["подарок", "gift", "цветы", "flowers"]),
        MoneyCategory(id: "transfers", name: "Transfers", emoji: "↔️", kind: .expense, keywords: [
            "перевод", "transfer", "сбп", "по номеру телефона", "внутренний перевод"]),
        MoneyCategory(id: "other", name: "Other", emoji: "•", kind: .expense),
        MoneyCategory(id: "salary", name: "Salary", emoji: "💼", kind: .income, keywords: ["зарплата", "заработная плата", "salary", "аванс", "payroll"]),
        MoneyCategory(id: "freelance", name: "Freelance", emoji: "🧑‍💻", kind: .income, keywords: ["оплата по договору", "invoice", "фриланс"]),
        MoneyCategory(id: "cashback", name: "Cashback & interest", emoji: "🪙", kind: .income, keywords: ["кэшбэк", "кешбэк", "cashback", "проценты", "interest", "вознаграждение"]),
        MoneyCategory(id: "income-other", name: "Other income", emoji: "➕", kind: .income),
    ]
}

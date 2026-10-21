import Foundation

/// One line that understands sums ("2+2*3", "15% of 200", "1200 + 10%"), units ("10 km in mi",
/// "180 cm в ft", "30 c to f") and money ("100 usd in rub", "€50 to $"). Currency rates come from
/// open.er-api.com (free, daily), cached for six hours.
enum Calculator {
    struct Answer: Equatable {
        var value: String
        var detail: String
    }

    static func evaluate(_ raw: String, rates: [String: Double]) -> Answer? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty else { return nil }
        if let conversion = convert(text, rates: rates) { return conversion }
        return arithmetic(text)
    }

    // MARK: Arithmetic

    private static func arithmetic(_ text: String) -> Answer? {
        var expression = text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "^", with: "**").replacingOccurrences(of: " ", with: "")
        // "15%of200" → 15/100*200; "1200+10%" → 1200*(1+10/100).
        expression = expression.replacingOccurrences(of: #"([\d.]+)%of([\d.]+)"#, with: "($1/100*$2)", options: .regularExpression)
        expression = expression.replacingOccurrences(of: #"([\d.)]+)([+-])([\d.]+)%"#, with: "($1*(1$2$3/100))", options: .regularExpression)
        expression = expression.replacingOccurrences(of: #"([\d.]+)%"#, with: "($1/100)", options: .regularExpression)
        guard expression.range(of: #"\d"#, options: .regularExpression) != nil,
              var parser = Parser(expression), let value = parser.parse(), value.isFinite else { return nil }
        return Answer(value: format(value), detail: text)
    }

    /// A small, safe evaluator: numbers, + − × ÷, ** for powers, brackets and sqrt(). Anything else
    /// makes it give up rather than guess.
    private struct Parser {
        private let chars: [Character]
        private var index = 0

        init?(_ text: String) {
            guard text.range(of: #"^[\d.+\-*/()a-z]+$"#, options: .regularExpression) != nil else { return nil }
            chars = Array(text)
        }

        mutating func parse() -> Double? {
            guard let value = sum(), index == chars.count else { return nil }
            return value
        }

        private mutating func sum() -> Double? {
            guard var value = product() else { return nil }
            while index < chars.count, chars[index] == "+" || chars[index] == "-" {
                let op = chars[index]; index += 1
                guard let next = product() else { return nil }
                value = op == "+" ? value + next : value - next
            }
            return value
        }

        private mutating func product() -> Double? {
            guard var value = power() else { return nil }
            while index < chars.count, chars[index] == "*" || chars[index] == "/" {
                let op = chars[index]; index += 1
                guard let next = power() else { return nil }
                value = op == "*" ? value * next : value / next
            }
            return value
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if index + 1 < chars.count, chars[index] == "*", chars[index + 1] == "*" {
                index += 2
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        private mutating func unary() -> Double? {
            if index < chars.count, chars[index] == "-" {
                index += 1
                return unary().map { -$0 }
            }
            return atom()
        }

        private mutating func atom() -> Double? {
            guard index < chars.count else { return nil }
            if chars[index] == "(" {
                index += 1
                guard let value = sum(), index < chars.count, chars[index] == ")" else { return nil }
                index += 1
                return value
            }
            if chars[index].isLetter {
                var name = ""
                while index < chars.count, chars[index].isLetter { name.append(chars[index]); index += 1 }
                guard name == "sqrt", let value = atom() else { return nil }
                return value.squareRoot()
            }
            var number = ""
            while index < chars.count, chars[index].isNumber || chars[index] == "." { number.append(chars[index]); index += 1 }
            return Double(number)
        }
    }

    // MARK: Units and money

    private static let unitAliases: [String: Dimension] = [
        "m": UnitLength.meters, "meter": UnitLength.meters, "meters": UnitLength.meters, "м": UnitLength.meters,
        "km": UnitLength.kilometers, "км": UnitLength.kilometers, "cm": UnitLength.centimeters, "см": UnitLength.centimeters,
        "mm": UnitLength.millimeters, "мм": UnitLength.millimeters, "mi": UnitLength.miles, "mile": UnitLength.miles, "miles": UnitLength.miles,
        "ft": UnitLength.feet, "feet": UnitLength.feet, "in": UnitLength.inches, "inch": UnitLength.inches, "yd": UnitLength.yards,
        "kg": UnitMass.kilograms, "кг": UnitMass.kilograms, "g": UnitMass.grams, "г": UnitMass.grams, "lb": UnitMass.pounds,
        "lbs": UnitMass.pounds, "oz": UnitMass.ounces, "t": UnitMass.metricTons, "т": UnitMass.metricTons,
        "c": UnitTemperature.celsius, "°c": UnitTemperature.celsius, "f": UnitTemperature.fahrenheit, "°f": UnitTemperature.fahrenheit,
        "k": UnitTemperature.kelvin,
        "l": UnitVolume.liters, "л": UnitVolume.liters, "ml": UnitVolume.milliliters, "мл": UnitVolume.milliliters,
        "gal": UnitVolume.gallons, "cup": UnitVolume.cups, "cups": UnitVolume.cups,
        "km/h": UnitSpeed.kilometersPerHour, "kmh": UnitSpeed.kilometersPerHour, "км/ч": UnitSpeed.kilometersPerHour,
        "mph": UnitSpeed.milesPerHour, "m/s": UnitSpeed.metersPerSecond, "м/с": UnitSpeed.metersPerSecond, "kn": UnitSpeed.knots,
        "m2": UnitArea.squareMeters, "m²": UnitArea.squareMeters, "km2": UnitArea.squareKilometers, "ft2": UnitArea.squareFeet,
        "ha": UnitArea.hectares, "acre": UnitArea.acres, "acres": UnitArea.acres,
        "b": UnitInformationStorage.bytes, "kb": UnitInformationStorage.kilobytes, "mb": UnitInformationStorage.megabytes,
        "gb": UnitInformationStorage.gigabytes, "tb": UnitInformationStorage.terabytes,
        "s": UnitDuration.seconds, "sec": UnitDuration.seconds, "min": UnitDuration.minutes, "мин": UnitDuration.minutes,
        "h": UnitDuration.hours, "hr": UnitDuration.hours, "ч": UnitDuration.hours,
    ]

    private static let currencySymbols: [String: String] = ["$": "USD", "€": "EUR", "₽": "RUB", "£": "GBP", "¥": "JPY", "₸": "KZT", "₺": "TRY"]

    private static func convert(_ text: String, rates: [String: Double]) -> Answer? {
        var line = text
        for (symbol, code) in currencySymbols { line = line.replacingOccurrences(of: symbol, with: " \(code.lowercased()) ") }
        let pattern = #"^\s*([\d.]+)\s*([^\s\d]+)\s+(?:in|to|в|into|->|=)\s+([^\s\d]+)\s*$"#
        let swapped = #"^\s*([^\s\d]+)\s*([\d.]+)\s+(?:in|to|в|into|->|=)\s+([^\s\d]+)\s*$"#
        var amount: Double?, from = "", to = ""
        if let match = line.range(of: pattern, options: .regularExpression) {
            let parts = captures(String(line[match]), pattern)
            amount = Double(parts[0]); from = parts[1]; to = parts[2]
        } else if let match = line.range(of: swapped, options: .regularExpression) {
            let parts = captures(String(line[match]), swapped)
            amount = Double(parts[1]); from = parts[0]; to = parts[2]
        }
        guard let amount else { return nil }
        if let a = unitAliases[from], let b = unitAliases[to], type(of: a) == type(of: b) {
            let value = Measurement(value: amount, unit: a).converted(to: b).value
            return Answer(value: "\(format(value)) \(to)", detail: "\(format(amount)) \(from)")
        }
        let codeFrom = from.uppercased(), codeTo = to.uppercased()
        if let rateFrom = rates[codeFrom], let rateTo = rates[codeTo], rateFrom > 0 {
            let value = amount / rateFrom * rateTo
            return Answer(value: "\(format(value, money: true)) \(codeTo)", detail: "\(format(amount, money: true)) \(codeFrom) · 1 \(codeFrom) = \(format(rateTo / rateFrom, money: true)) \(codeTo)")
        }
        return nil
    }

    private static func captures(_ text: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    static func format(_ value: Double, money: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = money ? 2 : (abs(value) < 1 ? 6 : 4)
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

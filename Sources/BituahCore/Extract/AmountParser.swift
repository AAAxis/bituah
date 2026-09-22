import Foundation

/// Money amounts in shekels. Handles `1,500 ש"ח`, `₪245.50`, `245.5 שח`, `NIS 380`, `380.00 ILS`,
/// OCR-mangled thousands separators (`1.500` when the doc clearly means 1500) and the words אין/ללא (= 0).
public enum AmountParser {

    public struct Found: Equatable {
        public var value: Double
        public var raw: String
        public var location: Int
        public var hasCurrency: Bool
        public var isPercent: Bool
    }

    static let currencyWords = "(?:₪|ש\"ח|שח|ש''ח|ש\\.ח|NIS|ILS|שקלים|שקל)"
    // number, optionally surrounded by a currency marker on either side
    static let amount = Pattern(
        "(?:" + currencyWords + "\\s*)?(?<![0-9.,])(\\d{1,3}(?:,\\d{3})+(?:\\.\\d{1,2})?|\\d+(?:\\.\\d{1,2})?)(?![0-9])(\\s*%)?(?:\\s*" + currencyWords + ")?"
    )
    static let zeroWords = Pattern("(?:^|\\s|\\()(אין|ללא|לא חל|פטור|לא רלוונטי|0)(?:\\s|$|\\)|\\.)")

    public static func all(in line: String) -> [Found] {
        var out: [Found] = []
        for m in amount.matches(in: line) {
            guard let numText = m.groups[0] else { continue }
            let isPercent = m.groups.count > 1 && m.groups[1] != nil
            let hasCurrency = m.text.count > numText.count + (isPercent ? 1 : 0)
            let cleaned = numText.replacingOccurrences(of: ",", with: "")
            guard let v = Double(cleaned) else { continue }
            out.append(Found(value: v, raw: m.text.trimmingCharacters(in: .whitespaces), location: m.location,
                             hasCurrency: hasCurrency, isPercent: isPercent))
        }
        return out
    }

    /// "אין", "ללא", "0" and friends mean an explicit zero (e.g. no deductible).
    public static func mentionsZero(_ line: String) -> Bool { zeroWords.test(line) }

    /// Looks like a date (dd/mm/yyyy) rather than money — used to filter candidates.
    static let datey = Pattern("^\\s*\\d{1,4}[./-]\\d{1,2}[./-]\\d{2,4}\\s*$")
    public static func looksLikeDate(_ s: String) -> Bool { datey.test(s) }
}

import Foundation

/// Parses the date formats seen in Israeli insurance paperwork into ISO-8601 (`YYYY-MM-DD`).
/// Israeli documents are day-first (`31/12/2026`); ISO (`2026-12-31`) and Hebrew month names are also handled.
public enum DateParser {

    public struct Found: Equatable {
        public var iso: String
        public var raw: String
        public var location: Int   // UTF-16 offset in the line, for proximity scoring
        public var wasReversed: Bool
    }

    static let numeric = Pattern("(?<![0-9])(\\d{1,4})[./\\-](\\d{1,2})[./\\-](\\d{2,4})(?![0-9])")
    static let hebrewMonths: [String: Int] = [
        "ינואר": 1, "פברואר": 2, "מרץ": 3, "מרס": 3, "אפריל": 4, "מאי": 5, "יוני": 6,
        "יולי": 7, "אוגוסט": 8, "ספטמבר": 9, "אוקטובר": 10, "נובמבר": 11, "דצמבר": 12,
    ]
    static let hebrewMonthDate = Pattern("(?<![0-9])(\\d{1,2})\\s+ב?(ינואר|פברואר|מרץ|מרס|אפריל|מאי|יוני|יולי|אוגוסט|ספטמבר|אוקטובר|נובמבר|דצמבר),?\\s+(\\d{4})")

    public static func all(in line: String) -> [Found] {
        var out: [Found] = []
        for m in numeric.matches(in: line) {
            let a = m.groups[0]!, b = m.groups[1]!, c = m.groups[2]!
            if let iso = assemble(a, b, c) {
                out.append(Found(iso: iso, raw: m.text, location: m.location, wasReversed: false))
            } else if let iso = assemble(String(c.reversed()), String(b.reversed()), String(a.reversed())) {
                // "6202/10/10" — a visual-order date that survived line repair.
                out.append(Found(iso: iso, raw: m.text, location: m.location, wasReversed: true))
            }
        }
        for m in hebrewMonthDate.matches(in: line) {
            if let d = Int(m.groups[0]!), let mo = hebrewMonths[m.groups[1]!], let y = Int(m.groups[2]!),
               let iso = iso(y: y, m: mo, d: d) {
                out.append(Found(iso: iso, raw: m.text, location: m.location, wasReversed: false))
            }
        }
        return out.sorted { $0.location < $1.location }
    }

    /// Try the day-first reading, then ISO year-first.
    static func assemble(_ a: String, _ b: String, _ c: String) -> String? {
        guard let x = Int(a), let y = Int(b), let z = Int(c) else { return nil }
        if a.count == 4 { return iso(y: x, m: y, d: z) }                       // 2026-12-31
        if c.count == 4 { return iso(y: z, m: y, d: x) }                       // 31/12/2026
        if c.count == 2 { return iso(y: expandYear(z), m: y, d: x) }           // 31/12/26
        return nil
    }

    static func expandYear(_ yy: Int) -> Int { yy < 50 ? 2000 + yy : 1900 + yy }

    static func iso(y: Int, m: Int, d: Int) -> String? {
        guard (1990...2100).contains(y), (1...12).contains(m), (1...31).contains(d) else { return nil }
        var comps = DateComponents(); comps.year = y; comps.month = m; comps.day = d
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: comps), cal.component(.day, from: date) == d else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    public static func compare(_ a: String, _ b: String) -> Int { a < b ? -1 : (a == b ? 0 : 1) }
}

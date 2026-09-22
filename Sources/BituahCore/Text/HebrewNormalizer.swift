import Foundation
import CoreGraphics

/// Hebrew-specific text clean-up that runs on every line before extraction, whatever the source.
///
/// Problems it addresses:
///  * Unicode noise: gershayim (״) vs ASCII quote, curly quotes, maqaf (־), NBSP, niqqud, bidi control marks.
///  * "Visual order" text layers: many Israeli PDFs (and some OCR engines) store Hebrew reversed —
///    `הסילופ רפסמ` instead of `מספר פוליסה`. Digits inside such lines are reversed too (`8102948` for `8492018`).
///    We score three repair hypotheses against a lexicon of insurance keywords and keep the best one.
public enum HebrewNormalizer {

    // MARK: Character-level clean-up

    static let bidiControls: Set<Unicode.Scalar> = {
        var s = Set<Unicode.Scalar>()
        for v in [0x200E, 0x200F, 0x061C, 0xFEFF, 0x200B, 0x200C, 0x200D] { s.insert(Unicode.Scalar(v)!) }
        for v in 0x202A...0x202E { s.insert(Unicode.Scalar(v)!) }
        for v in 0x2066...0x2069 { s.insert(Unicode.Scalar(v)!) }
        return s
    }()

    public static func cleanCharacters(_ input: String) -> String {
        // NFKC folds Hebrew presentation forms (U+FB1D…FB4F) back to base letters + points.
        let folded = input.precomposedStringWithCompatibilityMapping
        var out = String.UnicodeScalarView()
        for u in folded.unicodeScalars {
            if bidiControls.contains(u) { continue }
            switch u.value {
            case 0x0591...0x05C7:                 // niqqud / cantillation
                continue
            case 0x05F4, 0x201C, 0x201D, 0x2033:  // ״ “ ” ″
                out.append("\"")
            case 0x05F3, 0x2018, 0x2019, 0x2032:  // ׳ ‘ ’ ′
                out.append("'")
            case 0x05BE, 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2212: // ־ ‐ ‑ ‒ – — −
                out.append("-")
            case 0x00A0, 0x2007, 0x202F, 0x2009, 0x200A, 0x3000:
                out.append(" ")
            default:
                out.append(u)
            }
        }
        var s = String(out)
        s = Pattern("[ \\t]+").replace(in: s, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Reversal detection

    /// Insurance vocabulary in *logical* order. Weighted by length so long, unambiguous words dominate.
    static let lexicon: [String] = [
        // label bigrams first: they break ties between word-order hypotheses
        "מספר פוליסה", "תעודת זהות", "מספר תעודת", "פרמיה חודשית", "השתתפות עצמית", "תקופת הביטוח", "תקופת ביטוח",
        "חברה לביטוח", "חברת הביטוח", "שם המבוטח", "סוג ביטוח", "עד תאריך", "פרמיה שנתית", "דמי ביטוח",
        "פוליסה", "פוליסת", "ביטוח", "הביטוח", "מבוטח", "המבוטח", "מבטח", "המבטח",
        "תעודת", "זהות", "פרמיה", "חודשית", "חודשי", "שנתית", "תקופת", "תקופה",
        "השתתפות", "עצמית", "תאריך", "מתאריך", "תחילת", "סיום", "תום", "תוקף",
        "חברה", "חברת", "לביטוח", "בריאות", "חיים", "רכב", "דירה", "פנסיה", "סיעוד",
        "מספר", "שם", "סוג", "ענף", "כתובת", "טלפון", "סכום", "כיסוי", "כיסויים",
        "תשלום", "לתשלום", "הראל", "מגדל", "כלל", "הפניקס", "מנורה", "מבטחים", "איילון",
        "הכשרה", "שלמה", "ישיר", "ליברה", "ווישור", "שירביט", "ישראל", "פרטי", "נתוני",
    ]

    static func lexiconScore(_ s: String) -> Int {
        var score = 0
        for w in lexicon {
            let n = w.count
            var searchRange = s.startIndex..<s.endIndex
            while let r = s.range(of: w, range: searchRange) {
                score += n >= 4 ? n : 1
                searchRange = r.upperBound..<s.endIndex
            }
        }
        return score
    }

    static let ltrRun = Pattern("[0-9A-Za-z](?:[0-9A-Za-z./,\\-]*[0-9A-Za-z])?")
    static let hebrewLetters = Pattern("[\\u05D0-\\u05EA]")
    static let latinLetters = Pattern("[A-Za-z]")

    public static func containsHebrew(_ s: String) -> Bool { hebrewLetters.test(s) }

    /// Hypothesis A: the whole line was stored in visual order. Reverse it, then re-reverse LTR runs
    /// (numbers, dates, Latin) which were visually LTR and therefore got flipped by the full reverse.
    static func repairFullReverse(_ s: String) -> String {
        let reversed = String(s.reversed())
        return reverseLTRRuns(reversed)
    }

    static func reverseLTRRuns(_ s: String) -> String {
        var result = s
        // Iterate from the end so earlier ranges stay valid.
        for m in ltrRun.matches(in: s).reversed() {
            result.replaceSubrange(m.range, with: String(m.text.reversed()))
        }
        return result
    }

    /// Hypothesis B: each Hebrew word is reversed but word order is fine.
    static func repairWordChars(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let w = String(word)
            return containsHebrew(w) ? String(w.reversed()) : w
        }.joined(separator: " ")
    }

    /// Hypothesis C: the words are in reverse order but each word's characters are fine.
    static func repairWordOrder(_ s: String) -> String {
        s.split(separator: " ").reversed().joined(separator: " ")
    }

    public struct Repair: Equatable {
        public var text: String
        public var reversed: Bool
    }

    /// Returns the line in logical order. Only touches lines that contain Hebrew, and only when
    /// a repair hypothesis clearly beats the original on lexicon hits.
    public static func repairOrder(_ s: String) -> Repair {
        guard containsHebrew(s) else { return Repair(text: s, reversed: false) }
        let original = lexiconScore(s)
        let candidates: [(String, Int)] = [repairFullReverse(s), repairWordChars(s), repairWordOrder(s)]
            .map { ($0, lexiconScore($0)) }
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 > original, best.1 >= 4 else {
            return Repair(text: s, reversed: false)
        }
        return Repair(text: best.0, reversed: true)
    }

    // MARK: Line-level pipeline

    public static func normalize(_ lines: [TextLine]) -> [TextLine] {
        let merged = mergeRowFragments(lines)
        var out: [TextLine] = merged.compactMap { line in
            let cleaned = cleanCharacters(line.text)
            guard !cleaned.isEmpty else { return nil }
            let repaired = repairOrder(cleaned)
            var out = line
            out.text = repaired.text
            out.wasReversed = repaired.reversed
            return out
        }
        if digitsLookInverted(out.map(\.text)) {
            // Hebrew rows and bare numeric rows (a value cell on its own line); Latin prose is left alone.
            for i in out.indices where containsHebrew(out[i].text) || !latinLetters.test(out[i].text) {
                out[i].text = reverseLTRRuns(out[i].text)
                out[i].wasReversed = true
            }
        }
        return out
    }

    // MARK: Document-level digit inversion

    static let wellFormedDate = Pattern("^\\d{1,2}[./-]\\d{1,2}[./-](?:\\d{4}|\\d{2})$")
    static let wellFormedGroupedAmount = Pattern("^\\d{1,3}(?:,\\d{3})+(?:\\.\\d{1,2})?$")
    static let wellFormedDecimal = Pattern("^\\d+\\.\\d{2}$")

    /// Some text layers keep Hebrew in logical order but digits mirrored (`810294830` for `038492018`) —
    /// what PDFKit produces from a visual-order layer after its own bidi pass. Individual numbers can't
    /// tell us their orientation, but dates and grouped amounts can: a document where the mirrored
    /// reading is well-formed more often than the literal one is treated as digit-inverted as a whole.
    public static func digitsLookInverted(_ texts: [String]) -> Bool {
        var literal = 0, mirrored = 0
        for t in texts where containsHebrew(t) {
            for m in ltrRun.matches(in: t) {
                let a = m.text, b = String(a.reversed())
                guard a != b, a.contains(where: \.isNumber) else { continue }
                let (la, lb) = (wellFormedScore(a), wellFormedScore(b))
                if la > lb { literal += 1 } else if lb > la { mirrored += 1 }
            }
        }
        return mirrored >= 2 && mirrored > literal
    }

    static func wellFormedScore(_ s: String) -> Int {
        var score = 0
        if wellFormedDate.test(s), !DateParser.all(in: s).isEmpty, DateParser.all(in: s)[0].wasReversed == false { score += 2 }
        if wellFormedGroupedAmount.test(s) { score += 2 }
        if wellFormedDecimal.test(s) { score += 1 }
        return score
    }

    /// Table cells frequently come out of PDFKit/Tesseract as separate "lines" that share a baseline.
    /// Join them (right-to-left for Hebrew rows) so `label … value` lookups see one row.
    static func mergeRowFragments(_ lines: [TextLine]) -> [TextLine] {
        var result: [TextLine] = []
        for line in lines {
            guard !line.bbox.isNull, let last = result.last, !last.bbox.isNull, last.page == line.page else {
                result.append(line); continue
            }
            let h = max(last.bbox.height, line.bbox.height, 1)
            let sameRow = abs(last.bbox.midY - line.bbox.midY) < 0.4 * h
            let horizontallyDisjoint = line.bbox.minX >= last.bbox.maxX - 1 || line.bbox.maxX <= last.bbox.minX + 1
            guard sameRow, horizontallyDisjoint else { result.append(line); continue }
            var merged = last
            let rtl = containsHebrew(last.text) || containsHebrew(line.text)
            let leftFirst = line.bbox.minX < last.bbox.minX
            // RTL row: the right-hand fragment is read first; LTR row: the left-hand one.
            let lastFirst = (rtl == leftFirst)
            let (first, second) = lastFirst ? (last.text, line.text) : (line.text, last.text)
            merged.text = first + " " + second
            merged.bbox = last.bbox.union(line.bbox)
            merged.confidence = min(last.confidence, line.confidence)
            result[result.count - 1] = merged
        }
        return result
    }
}

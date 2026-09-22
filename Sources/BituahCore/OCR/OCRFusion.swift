import Foundation
import CoreGraphics

/// Merges two OCR passes over the same page by geometry:
///  * `primary` — Tesseract `heb`: reliable on Hebrew words, weak on thin/bold digit strings;
///  * `numeric` — Apple Vision (no Hebrew model): reads digits, dates and Latin very reliably.
///
/// Every numeric token from the digit engine replaces whatever the primary engine read at the same
/// position on the same row (or is inserted if the primary engine dropped it). Rows are rebuilt in
/// reading order from word boxes: right-to-left for Hebrew rows, left-to-right otherwise.
/// This is the on-device analogue of "ensemble by specialty" and costs one extra Vision pass (~0.3 s).
public enum OCRFusion {

    public struct Result {
        public var lines: [TextLine]
        public var replacedTokens: Int
    }

    static let numericToken = Pattern("^[₪$]?[0-9][0-9.,/\\-:]*[0-9%]?[₪]?$|^[0-9]$")

    public static func isNumericToken(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "()[]:;,. "))
        return !t.isEmpty && numericToken.test(t)
    }

    public static func fuse(primary: [TextLine], numeric: [TextLine]) -> Result {
        var lines = primary
        var replaced = 0
        let tokens = numeric.flatMap { $0.words }.filter {
            isNumericToken($0.text) && $0.text.filter(\.isNumber).count >= 1 && $0.confidence >= 0.5
        }

        for token in tokens {
            // Row: the primary line with the best vertical overlap.
            var bestIdx: Int?
            var bestOverlap: CGFloat = 0
            for (i, l) in lines.enumerated() where !l.bbox.isNull {
                let ov = verticalOverlap(l.bbox, token.bbox)
                if ov > bestOverlap { bestOverlap = ov; bestIdx = i }
            }
            let cleanToken = token.text.trimmingCharacters(in: CharacterSet(charactersIn: "()[]:;, "))
            guard let idx = bestIdx, bestOverlap >= 0.5 else {
                // Primary engine has no row here: add the token as its own line.
                lines.append(TextLine(text: cleanToken, page: numeric.first?.page ?? 0, bbox: token.bbox,
                                      confidence: token.confidence, words: [TextWord(text: cleanToken, bbox: token.bbox, confidence: token.confidence)]))
                replaced += 1
                continue
            }
            var line = lines[idx]
            let covered = line.words.filter { horizontalOverlap($0.bbox, token.bbox) >= 0.3 }
            // A digit engine without a Hebrew model reads Hebrew glyphs as digits ("מספר" → "7901"):
            // never overwrite a word the primary engine read as Hebrew.
            if covered.contains(where: { hebrewLetterCount($0.text) >= 2 }) { continue }
            // Don't trade a longer digit string for a shorter one (dropped digits in the ID).
            let tokenDigits = cleanToken.filter(\.isNumber).count
            if covered.contains(where: { $0.text.filter(\.isNumber).count > tokenDigits }) { continue }
            // Drop primary words that the token covers horizontally (garbage read of the same glyphs).
            let before = line.words.count
            line.words.removeAll { w in horizontalOverlap(w.bbox, token.bbox) >= 0.3 }
            // Don't duplicate a token the primary engine already read correctly next to it.
            let already = line.words.contains { $0.text == cleanToken }
            if !already {
                line.words.append(TextWord(text: cleanToken, bbox: token.bbox, confidence: token.confidence))
                if before != line.words.count - 1 || before == line.words.count { replaced += 1 }
            }
            line.bbox = line.bbox.union(token.bbox)
            line.text = rebuildText(line.words)
            lines[idx] = line
        }
        // Reading order: top to bottom, then right to left within a row.
        lines.sort { a, b in
            if a.page != b.page { return a.page < b.page }
            let h = max(a.bbox.height, b.bbox.height, 1)
            if abs(a.bbox.midY - b.bbox.midY) > h * 0.6 { return a.bbox.midY > b.bbox.midY }
            return a.bbox.maxX > b.bbox.maxX
        }
        return Result(lines: lines, replacedTokens: replaced)
    }

    static func hebrewLetterCount(_ s: String) -> Int {
        s.unicodeScalars.filter { (0x05D0...0x05EA).contains($0.value) }.count
    }

    static func rebuildText(_ words: [TextWord]) -> String {
        let rtl = words.contains { HebrewNormalizer.containsHebrew($0.text) }
        let ordered = rtl ? words.sorted { $0.bbox.maxX > $1.bbox.maxX } : words.sorted { $0.bbox.minX < $1.bbox.minX }
        return ordered.map(\.text).joined(separator: " ")
    }

    static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let ov = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard ov > 0 else { return 0 }
        return ov / max(1, min(a.height, b.height))
    }

    static func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let ov = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        guard ov > 0 else { return 0 }
        return ov / max(1, min(a.width, b.width))
    }
}

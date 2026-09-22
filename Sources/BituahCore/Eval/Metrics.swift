import Foundation

/// Accuracy measurement: per-field exact match against ground truth, plus CER/WER of OCR output
/// against the reference text (the native text layer of the same page).
public enum Metrics {

    // MARK: Edit distance

    public static func levenshtein<T: Hashable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Text normalization shared by reference and hypothesis so that punctuation/whitespace styles
    /// don't dominate the error rate.
    public static func normalizeForRate(_ s: String) -> String {
        var t = HebrewNormalizer.cleanCharacters(s)
        t = Pattern("[\\s]+").replace(in: t, with: " ")
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Character error rate: edit distance over reference length.
    public static func cer(reference: String, hypothesis: String) -> Double {
        let r = Array(normalizeForRate(reference)), h = Array(normalizeForRate(hypothesis))
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        return Double(levenshtein(r, h)) / Double(r.count)
    }

    /// Word error rate: edit distance over whitespace-separated tokens.
    public static func wer(reference: String, hypothesis: String) -> Double {
        let r = normalizeForRate(reference).split(separator: " ").map(String.init)
        let h = normalizeForRate(hypothesis).split(separator: " ").map(String.init)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        return Double(levenshtein(r, h)) / Double(r.count)
    }

    // MARK: Field comparison

    public static func fieldsMatch(_ key: String, predicted: JSONValue, truth: JSONValue) -> Bool {
        switch (predicted, truth) {
        case (.null, .null): return true
        case let (.number(a), .number(b)): return abs(a - b) < 0.005
        case let (.string(a), .string(b)):
            return HebrewNormalizer.cleanCharacters(a) == HebrewNormalizer.cleanCharacters(b)
        case let (.number(a), .string(b)): return Double(b).map { abs(a - $0) < 0.005 } ?? false
        case let (.string(a), .number(b)): return Double(a).map { abs($0 - b) < 0.005 } ?? false
        default: return false
        }
    }

    public struct DocScore {
        public var file: String
        public var perField: [(String, Bool, JSONValue, JSONValue)]   // key, match, predicted, truth
        public var correct: Int { perField.filter(\.1).count }
        public var total: Int { perField.count }
    }

    public static func score(file: String, predicted: PolicyFields, truth: JSONValue) -> DocScore {
        let pj = predicted.jsonObject
        var rows: [(String, Bool, JSONValue, JSONValue)] = []
        for key in PolicyFields.keys {
            let p = pj[key] ?? .null
            let t = truth[key] ?? .null
            rows.append((key, fieldsMatch(key, predicted: p, truth: t), p, t))
        }
        return DocScore(file: file, perField: rows)
    }

    // MARK: Report

    public static func markdownTable(scores: [DocScore]) -> String {
        var out = "| file | " + PolicyFields.keys.joined(separator: " | ") + " | score |\n"
        out += "|---|" + PolicyFields.keys.map { _ in "---" }.joined(separator: "|") + "|---|\n"
        for s in scores {
            out += "| \(s.file) | " + s.perField.map { $0.1 ? "✅" : "❌" }.joined(separator: " | ") + " | \(s.correct)/\(s.total) |\n"
        }
        var perField: [String: (Int, Int)] = [:]
        for s in scores { for (k, ok, _, _) in s.perField { perField[k, default: (0, 0)].0 += ok ? 1 : 0; perField[k, default: (0, 0)].1 += 1 } }
        out += "| **per field** | " + PolicyFields.keys.map { k in
            let (c, t) = perField[k] ?? (0, 0); return "\(c)/\(t)"
        }.joined(separator: " | ")
        let c = scores.map(\.correct).reduce(0, +), t = scores.map(\.total).reduce(0, +)
        out += " | **\(c)/\(t)** (\(String(format: "%.1f", t == 0 ? 0 : Double(c) * 100 / Double(t)))%) |\n"
        return out
    }
}

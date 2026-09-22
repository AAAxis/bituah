import Foundation

/// Keyword-anchored extraction over normalized lines.
///
/// Every field follows the same recipe:
///   1. find *anchor* lines that contain a label keyword (weighted by how specific the label is);
///   2. collect typed candidates (ID / number / date / amount) from the text after the label on the
///      same line and from the next 1–2 lines (labels and values sit on separate rows in most
///      Israeli policy tables);
///   3. score = label weight − row distance + validation bonus (ID checksum, currency marker, …);
///   4. return the best candidate with the line it came from as evidence.
///
/// Deterministic, explainable, and fast enough to run on every keystroke on a phone.
public struct FieldExtractor {
    public let lines: [TextLine]
    let texts: [String]

    public init(lines: [TextLine]) {
        self.lines = lines
        self.texts = lines.map(\.text)
    }

    public typealias Keyword = (String, Double)

    struct Anchor {
        var lineIndex: Int
        var keyword: String
        var weight: Double
        var after: String      // text after the keyword on the same line
    }

    // MARK: Shared helpers

    func anchors(_ keywords: [Keyword]) -> [Anchor] {
        var out: [Anchor] = []
        for (i, t) in texts.enumerated() {
            for (kw, w) in keywords {
                if let r = t.range(of: kw, options: .caseInsensitive) {
                    out.append(Anchor(lineIndex: i, keyword: kw, weight: w, after: String(t[r.upperBound...])))
                    break // one (the most specific, listed first) keyword per line
                }
            }
        }
        return out
    }

    /// Regions to look for a value, ordered by row distance: (distance, text).
    func valueRegions(for a: Anchor, lookahead: Int = 2, includeWholeAnchorLine: Bool = false) -> [(Int, String)] {
        var regions: [(Int, String)] = [(0, includeWholeAnchorLine ? texts[a.lineIndex] : a.after)]
        for d in stride(from: 1, through: lookahead, by: 1) where a.lineIndex + d < texts.count {
            regions.append((d, texts[a.lineIndex + d]))
        }
        return regions
    }

    static func stripLabelPunctuation(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " :-–—|\t.,;"))
    }

    func sourceFactor(_ lineIndex: Int) -> Double { lines[lineIndex].confidence }

    // MARK: insured_id

    static let idKeywords: [Keyword] = [
        ("מספר תעודת זהות", 3), ("תעודת זהות", 3), ("מספר זהות", 3), ("מס' זהות", 3), ("מס. זהות", 3),
        ("ת.ז.", 2.5), ("ת.ז", 2.5), ("ת\"ז", 2.5), ("תעודת הזהות", 3), ("ID number", 2), ("ת.ז/ח.פ", 2), ("תז", 1),
    ]
    // 9 digits, optionally space-grouped; 8 digits only when contiguous (leading zero dropped).
    static let digitToken = Pattern("(?<![0-9\\-])(\\d(?: ?\\d){8}|\\d{8})(?![0-9\\-])")
    static let idNoise = ["רישוי", "טלפון", "נייד", "פקס", "ח.פ", "חשבון", "פוליסה", "רכב מס"]
    static let anyDigitToken = Pattern("(?<![0-9\\-/.])(\\d{8,9})(?![0-9\\-/.])")

    public func insuredId() -> (String, FieldEvidence)? {
        var best: (score: Double, value: String, line: Int, note: String?)?
        for a in anchors(Self.idKeywords) {
            for (dist, region) in valueRegions(for: a) {
                if dist > 0, Self.idNoise.contains(where: { region.contains($0) }) { continue }
                for m in Self.digitToken.matches(in: region) {
                    // Mirroring is only trusted when the line itself was stored in visual order.
                    guard let c = IsraeliID.candidate(from: m.text, allowMirror: lines[a.lineIndex + dist].wasReversed) else { continue }
                    // Checksum is a tie-breaker, not a gate: test fixtures and some foreign IDs fail it.
                    var score = a.weight * 2 - Double(dist) * 1.5 + (c.checksumOK ? 1 : 0)
                    if dist == 0 { score += 0.5 }
                    let note = c.wasReversed ? "digits were stored reversed; mirrored to pass ת.ז checksum" :
                               (c.checksumOK ? nil : "ת.ז checksum failed (value kept; verify manually)")
                    if best == nil || score > best!.score {
                        best = (score, c.value, a.lineIndex + dist, note)
                    }
                }
            }
        }
        if let b = best {
            let conf = min(1.0, 0.55 + b.score / 20) * sourceFactor(b.line)
            return (b.value, FieldEvidence(confidence: conf, evidence: texts[b.line], note: b.note))
        }
        // Fallback: any 9-digit token anywhere that passes the checksum.
        for (i, t) in texts.enumerated() {
            for m in Self.anyDigitToken.matches(in: t) {
                if IsraeliID.isValid(m.text), !t.contains("פוליסה") {
                    return (IsraeliID.canonical(m.text),
                            FieldEvidence(confidence: 0.45 * sourceFactor(i), evidence: t, note: "no ת.ז label found; matched by checksum only"))
                }
            }
        }
        return nil
    }

    // MARK: policy_number

    static let policyKeywords: [Keyword] = [
        ("מספר פוליסה", 3), ("מספר הפוליסה", 3), ("מס' פוליסה", 3), ("מס. פוליסה", 3), ("מס פוליסה", 3),
        ("פוליסה מספר", 3), ("פוליסה מס'", 3), ("פוליסה מס", 2.5), ("Policy number", 3), ("Policy No", 3), ("policy #", 3),
    ]
    static let policyToken = Pattern("(?<![0-9A-Za-z])([0-9][0-9A-Za-z\\-/.]*[0-9A-Za-z]|[0-9]{5,})(?![0-9A-Za-z])")

    public func policyNumber(excluding insuredId: String?) -> (String, FieldEvidence)? {
        var best: (score: Double, value: String, line: Int)?
        for a in anchors(Self.policyKeywords) {
            for (dist, region) in valueRegions(for: a) {
                for m in Self.policyToken.matches(in: region) {
                    let digits = m.text.filter(\.isNumber).count
                    guard digits >= 5, !AmountParser.looksLikeDate(m.text) else { continue }
                    if let id = insuredId, m.text.filter(\.isNumber) == id { continue }
                    var score = a.weight * 2 - Double(dist) * 1.5
                    if m.text.contains("-") || m.text.contains("/") { score += 0.5 }   // typical 1234567-24/01 shape
                    if best == nil || score > best!.score { best = (score, m.text, a.lineIndex + dist) }
                }
            }
        }
        guard let b = best else { return nil }
        let conf = min(1.0, 0.6 + b.score / 20) * sourceFactor(b.line)
        return (b.value, FieldEvidence(confidence: conf, evidence: texts[b.line]))
    }

    // MARK: company_name

    static let companyKeywords: [Keyword] = [
        ("שם חברת הביטוח", 3), ("חברת הביטוח", 2), ("שם המבטח", 3), ("המבטח", 2), ("חברה מבטחת", 2), ("שם החברה", 2),
    ]
    static let legalSuffix = Pattern("בע\"מ|בע''מ|בעמ\\b")

    public func companyName() -> (String, FieldEvidence)? {
        // 1. Labelled value.
        for a in anchors(Self.companyKeywords) {
            for (dist, region) in valueRegions(for: a, lookahead: 1) {
                let candidate = Self.stripLabelPunctuation(region)
                if let (ins, _) = Insurer.match(in: candidate), candidate.count <= 70 {
                    let value = Self.tidyCompany(candidate, fallback: ins.canonical)
                    let conf = min(1.0, 0.75 + a.weight / 10 - Double(dist) * 0.05) * sourceFactor(a.lineIndex + dist)
                    return (value, FieldEvidence(confidence: conf, evidence: texts[a.lineIndex + dist]))
                }
            }
        }
        // 2. Letterhead: an early short line naming an insurer.
        for (i, t) in texts.prefix(8).enumerated() {
            if let (ins, _) = Insurer.match(in: t), t.count <= 60, (t.contains("ביטוח") || Self.legalSuffix.test(t)) {
                return (Self.tidyCompany(t, fallback: ins.canonical),
                        FieldEvidence(confidence: 0.7 * sourceFactor(i), evidence: t, note: "taken from letterhead"))
            }
        }
        // 3. Most-mentioned insurer anywhere → canonical legal name.
        var counts: [String: Int] = [:]
        for t in texts { if let (ins, _) = Insurer.match(in: t) { counts[ins.canonical, default: 0] += 1 } }
        if let (name, n) = counts.max(by: { $0.value < $1.value }) {
            return (name, FieldEvidence(confidence: 0.5, evidence: "\(n) mention(s) of insurer alias", note: "canonical name; document did not label the insurer"))
        }
        return nil
    }

    /// Keep the document's own wording when it is a clean legal name; otherwise fall back to canonical.
    static func tidyCompany(_ raw: String, fallback: String) -> String {
        var s = stripLabelPunctuation(raw)
        // Cut off anything after the legal suffix ("… בע"מ, רמת גן" → "… בע"מ").
        if let m = legalSuffix.first(in: s) {
            s = String(s[..<m.range.upperBound])
        }
        s = s.replacingOccurrences(of: "בע''מ", with: "בע\"מ").replacingOccurrences(of: "בעמ", with: "בע\"מ")
        // Must look like a company name: contains "ביטוח" or a legal suffix; else use the canonical one.
        if !(s.contains("ביטוח") || legalSuffix.test(s)) || s.count > 60 { return fallback }
        return s
    }

    // MARK: insurance_type

    static let typeKeywords: [Keyword] = [
        ("סוג ענף ביטוח", 5), ("סוג הביטוח", 5), ("סוג ביטוח", 5), ("ענף ביטוח", 5), ("סוג הפוליסה", 5),
        ("סוג פוליסה", 5), ("תכנית ביטוח", 3), ("שם התכנית", 3), ("ענף", 3), ("סוג מוצר", 3),
    ]

    public func insuranceType() -> (InsuranceType, FieldEvidence)? {
        var scores: [InsuranceType: Double] = [:]
        var evidenceLine: [InsuranceType: (Double, Int)] = [:]

        func credit(_ text: String, weight: Double, line: Int) {
            for t in InsuranceType.allCases {
                var hits = 0.0
                for k in InsuranceTypeLexicon.strong[t] ?? [] where text.contains(k) { hits += 3 }
                for k in InsuranceTypeLexicon.keywords[t] ?? [] where text.contains(k) { hits += 1 }
                guard hits > 0 else { continue }
                scores[t, default: 0] += hits * weight
                if evidenceLine[t] == nil || hits * weight > evidenceLine[t]!.0 { evidenceLine[t] = (hits * weight, line) }
            }
        }

        // Region A: the labelled "type" value (same line after label, else next line).
        for a in anchors(Self.typeKeywords) {
            let regions = valueRegions(for: a, lookahead: 1)
            let after = Self.stripLabelPunctuation(regions[0].1)
            if !after.isEmpty { credit(after, weight: a.weight, line: a.lineIndex) }
            else if regions.count > 1 { credit(regions[1].1, weight: a.weight, line: a.lineIndex + 1) }
        }
        // Region B: title block.
        for (i, t) in texts.prefix(4).enumerated() { credit(t, weight: 3, line: i) }
        // Region C: everything else, lightly.
        for (i, t) in texts.enumerated() { credit(t, weight: 0.3, line: i) }

        let ranked = scores.sorted { $0.value > $1.value }
        guard let top = ranked.first, top.value > 0 else { return nil }
        let second = ranked.dropFirst().first?.value ?? 0
        let margin = (top.value - second) / top.value
        let line = evidenceLine[top.key]!.1
        let conf = min(1.0, 0.5 + 0.5 * margin) * sourceFactor(line)
        return (top.key, FieldEvidence(confidence: conf, evidence: texts[line]))
    }

    // MARK: start_date / end_date

    static let periodKeywords: [Keyword] = [
        ("תקופת הביטוח", 3), ("תקופת ביטוח", 3), ("תקופת הפוליסה", 3), ("תקופת פוליסה", 3),
        ("תחילת הביטוח", 3), ("תחילת ביטוח", 3), ("תאריך תחילה", 3), ("תחילת תוקף", 3), ("תוקף הפוליסה", 2),
        ("מתאריך", 2), ("בתוקף מ", 2), ("תקופה", 1), ("תוקף", 1),
    ]
    static let startMarkers = ["מתאריך", "מ-", "החל מ", "תחילה", "תחילת", "מיום", "from"]
    static let endMarkers = ["עד תאריך", "עד ליום", "עד", "תום", "סיום", "until", "to"]
    static let excludeMarkers = ["הופק", "הפקה", "הודפס", "הדפסה", "לידה", "נכון ל", "נוצר", "עודכן", "חתימה", "issued", "printed"]

    public func period() -> (start: (String, FieldEvidence)?, end: (String, FieldEvidence)?) {
        struct Cand { var iso: String; var line: Int; var score: Double; var role: Int /* -1 start, 1 end, 0 unknown */; var reversed: Bool }
        var cands: [Cand] = []
        var seenLines = Set<Int>()

        for a in anchors(Self.periodKeywords) {
            for (dist, _) in valueRegions(for: a, lookahead: 2) {
                let li = a.lineIndex + dist
                guard !seenLines.contains(li) else { continue }
                seenLines.insert(li)
                let t = texts[li]
                if dist > 0, Self.excludeMarkers.contains(where: { t.contains($0) }) { continue }
                let found = DateParser.all(in: t)
                for (k, f) in found.enumerated() {
                    let prefix = String((t as NSString).substring(to: f.location).suffix(14))
                    var role = 0
                    if Self.startMarkers.contains(where: { prefix.contains($0) }) { role = -1 }
                    if Self.endMarkers.contains(where: { prefix.contains($0) }) { role = 1 }
                    if role == 0 { role = (found.count >= 2) ? (k == 0 ? -1 : 1) : 0 }
                    let score = a.weight * 2 - Double(dist) * 1.5 + (role != 0 ? 1 : 0)
                    cands.append(Cand(iso: f.iso, line: li, score: score, role: role, reversed: f.wasReversed))
                }
            }
        }

        if cands.isEmpty {
            // Fallback: every date in the document that is not an issue/birth date; min → start, max → end.
            var all: [(String, Int)] = []
            for (i, t) in texts.enumerated() where !Self.excludeMarkers.contains(where: { t.contains($0) }) {
                for f in DateParser.all(in: t) { all.append((f.iso, i)) }
            }
            guard let lo = all.min(by: { $0.0 < $1.0 }), let hi = all.max(by: { $0.0 < $1.0 }), lo.0 != hi.0 else { return (nil, nil) }
            let note = "no period label found; used earliest/latest dates in the document"
            return ((lo.0, FieldEvidence(confidence: 0.35 * sourceFactor(lo.1), evidence: texts[lo.1], note: note)),
                    (hi.0, FieldEvidence(confidence: 0.35 * sourceFactor(hi.1), evidence: texts[hi.1], note: note)))
        }

        let starts = cands.filter { $0.role == -1 }.sorted { $0.score > $1.score }
        let ends = cands.filter { $0.role == 1 }.sorted { $0.score > $1.score }
        var start = starts.first
        var end = ends.first
        if start == nil, end == nil {
            let byDate = cands.sorted { $0.iso < $1.iso }
            start = byDate.first
            end = byDate.count > 1 ? byDate.last : nil
        }
        var note: String?
        if let s = start, let e = end, e.iso < s.iso {
            swap(&start, &end)
            note = "start/end appeared swapped (RTL order); reordered chronologically"
        }
        func pack(_ c: Cand?) -> (String, FieldEvidence)? {
            guard let c = c else { return nil }
            var n = note
            if c.reversed { n = (n.map { $0 + "; " } ?? "") + "date digits were reversed in the source" }
            let conf = min(1.0, 0.55 + c.score / 16) * sourceFactor(c.line)
            return (c.iso, FieldEvidence(confidence: conf, evidence: texts[c.line], note: n))
        }
        return (pack(start), pack(end))
    }

    // MARK: monthly_premium_ils

    static let monthlyKeywords: [Keyword] = [
        ("פרמיה חודשית", 3), ("פרמיה חודשית לתשלום", 3), ("דמי ביטוח חודשיים", 3), ("תשלום חודשי", 3),
        ("פרמיה לחודש", 3), ("סה\"כ לחודש", 3), ("סך הכל לחודש", 3), ("עלות חודשית", 3), ("לחודש", 2),
        ("פרמיה", 1), ("דמי ביטוח", 1), ("premium", 1),
    ]
    static let annualKeywords: [Keyword] = [
        ("פרמיה שנתית", 3), ("דמי ביטוח שנתיים", 3), ("סה\"כ לשנה", 3), ("עלות שנתית", 3), ("לשנה", 2), ("שנתי", 1),
    ]

    func bestAmount(_ keywords: [Keyword], lookahead: Int = 1, skipAnchorsContaining: [String] = []) -> (Double, Int, Double, Bool)? {
        // returns (value, line, score, explicitZero)
        var best: (Double, Int, Double, Bool)?
        for a in anchors(keywords) {
            if skipAnchorsContaining.contains(where: { texts[a.lineIndex].contains($0) }) { continue }
            for (dist, region) in valueRegions(for: a, lookahead: lookahead) {
                if dist > 0, Self.excludeMarkers.contains(where: { region.contains($0) }) { continue }
                let amounts = AmountParser.all(in: region).filter { !$0.isPercent && !AmountParser.looksLikeDate($0.raw) }
                for m in amounts {
                    var score = a.weight * 2 - Double(dist) * 1.5 + (m.hasCurrency ? 1.5 : 0)
                    if dist == 0 { score += 0.5 }
                    if best == nil || score > best!.2 { best = (m.value, a.lineIndex + dist, score, false) }
                }
                if amounts.isEmpty, AmountParser.mentionsZero(region) {
                    let score = a.weight * 2 - Double(dist) * 1.5
                    if best == nil || score > best!.2 { best = (0, a.lineIndex + dist, score, true) }
                }
                if best != nil, dist == 0 { break }  // same-line hit is authoritative for this anchor
            }
        }
        return best
    }

    public func monthlyPremium() -> (Double, FieldEvidence)? {
        if let (v, line, score, _) = bestAmount(Self.monthlyKeywords, skipAnchorsContaining: ["שנתי", "לשנה", "שנתית"]), v > 0 {
            let conf = min(1.0, 0.55 + score / 16) * sourceFactor(line)
            return (v, FieldEvidence(confidence: conf, evidence: texts[line]))
        }
        if let (v, line, score, _) = bestAmount(Self.annualKeywords), v > 0 {
            let monthly = (v / 12 * 100).rounded() / 100
            let conf = min(0.6, 0.35 + score / 20) * sourceFactor(line)
            return (monthly, FieldEvidence(confidence: conf, evidence: texts[line], note: "derived: annual premium \(v) / 12"))
        }
        return nil
    }

    // MARK: deductible_ils

    static let deductibleKeywords: [Keyword] = [
        ("השתתפות עצמית", 3), ("השתתפות העצמית", 3), ("השתתפות", 2), ("deductible", 3),
    ]
    static let percentOnly = Pattern("\\d+(?:\\.\\d+)?\\s*%")

    public func deductible() -> (Double?, FieldEvidence)? {
        let anchorsFound = anchors(Self.deductibleKeywords)
        guard !anchorsFound.isEmpty else { return nil }
        if let (v, line, score, explicitZero) = bestAmount(Self.deductibleKeywords) {
            let conf = min(1.0, 0.55 + score / 16) * sourceFactor(line)
            return (v, FieldEvidence(confidence: conf, evidence: texts[line], note: explicitZero ? "document states no deductible" : nil))
        }
        // Label exists but only a percentage (or nothing) follows.
        let a = anchorsFound[0]
        for (_, region) in valueRegions(for: a, lookahead: 1) {
            if let m = Self.percentOnly.first(in: region) {
                return (nil, FieldEvidence(confidence: 0.5, evidence: region, note: "deductible is a percentage (\(m.text)), not a shekel amount"))
            }
        }
        return (nil, FieldEvidence(confidence: 0.3, evidence: texts[a.lineIndex], note: "label found but no amount next to it"))
    }
}

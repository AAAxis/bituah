import Foundation

/// How the eight fields are produced.
public enum ExtractionMode: String, CaseIterable, Sendable {
    case rules    // deterministic keyword extractor only (step 1)
    case model    // on-device language model over the normalized text only
    case hybrid   // rules first; the model fills fields the rules left empty or rated below threshold
}

/// A model that maps normalized document lines to the target fields.
public protocol FieldModel {
    var name: String { get }
    var isAvailable: Bool { get }
    func extract(lines: [String]) throws -> ModelDraft
}

/// Raw model answer before validation (all strings so a model cannot break the schema).
public struct ModelDraft: Sendable, Equatable {
    public var insuredId: String?
    public var companyName: String?
    public var policyNumber: String?
    public var insuranceType: String?
    public var startDate: String?
    public var endDate: String?
    public var monthlyPremiumILS: String?
    public var deductibleILS: String?
    public var rawText: String

    public init(insuredId: String? = nil, companyName: String? = nil, policyNumber: String? = nil, insuranceType: String? = nil,
                startDate: String? = nil, endDate: String? = nil, monthlyPremiumILS: String? = nil, deductibleILS: String? = nil,
                rawText: String = "") {
        self.insuredId = insuredId; self.companyName = companyName; self.policyNumber = policyNumber
        self.insuranceType = insuranceType; self.startDate = startDate; self.endDate = endDate
        self.monthlyPremiumILS = monthlyPremiumILS; self.deductibleILS = deductibleILS; self.rawText = rawText
    }

    /// Validate and canonicalize the draft into schema-typed fields. Anything malformed becomes nil.
    public func validated(modelName: String) -> (PolicyFields, [String: FieldEvidence]) {
        var f = PolicyFields()
        var ev: [String: FieldEvidence] = [:]
        func note(_ key: String, _ raw: String?, conf: Double = 0.7) {
            ev[key] = FieldEvidence(confidence: conf, evidence: "model:\(modelName) → \(raw ?? "null")", note: "value produced by on-device model")
        }
        if let s = insuredId {
            let digits = s.filter(\.isNumber)
            if (8...9).contains(digits.count) { f.insuredId = IsraeliID.canonical(digits); note("insured_id", s, conf: IsraeliID.isValid(digits) ? 0.8 : 0.6) }
        }
        if let s = companyName {
            let c = HebrewNormalizer.cleanCharacters(s)
            if c.count >= 3 { f.companyName = FieldExtractor.tidyCompany(c, fallback: c); note("company_name", s) }
        }
        if let s = policyNumber {
            let c = HebrewNormalizer.cleanCharacters(s).trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            if c.filter(\.isNumber).count >= 4, !AmountParser.looksLikeDate(c) { f.policyNumber = c; note("policy_number", s) }
        }
        if let s = insuranceType {
            let c = HebrewNormalizer.cleanCharacters(s)
            if let t = InsuranceType(rawValue: c) ?? InsuranceType.allCases.first(where: { c.contains($0.rawValue) }) {
                f.insuranceType = t; note("insurance_type", s)
            }
        }
        if let s = startDate, let d = DateParser.all(in: s).first { f.startDate = d.iso; note("start_date", s) }
        if let s = endDate, let d = DateParser.all(in: s).first { f.endDate = d.iso; note("end_date", s) }
        if let s = monthlyPremiumILS, let a = AmountParser.all(in: s).first, !a.isPercent { f.monthlyPremiumILS = a.value; note("monthly_premium_ils", s) }
        if let s = deductibleILS {
            if let a = AmountParser.all(in: s).first, !a.isPercent { f.deductibleILS = a.value; note("deductible_ils", s) }
            else if AmountParser.mentionsZero(s) { f.deductibleILS = 0; note("deductible_ils", s) }
        }
        return (f, ev)
    }
}

/// Hybrid policy: keep a rules value when it exists and its confidence is at least `threshold`;
/// otherwise take the model's validated value. Provenance is recorded in the evidence note.
public enum HybridMerger {
    public static func merge(rules: (PolicyFields, [String: FieldEvidence]), model: (PolicyFields, [String: FieldEvidence]),
                             threshold: Double = 0.8) -> (PolicyFields, [String: FieldEvidence]) {
        var f = rules.0
        var ev = rules.1
        let rj = rules.0.jsonObject, mj = model.0.jsonObject
        for key in PolicyFields.keys {
            let rulesHas = rj[key] != nil && rj[key] != .null
            let conf = rules.1[key]?.confidence ?? 0
            let modelHas = mj[key] != nil && mj[key] != .null
            guard modelHas, !(rulesHas && conf >= threshold) else { continue }
            switch key {
            case "insured_id": f.insuredId = model.0.insuredId
            case "company_name": f.companyName = model.0.companyName
            case "policy_number": f.policyNumber = model.0.policyNumber
            case "insurance_type": f.insuranceType = model.0.insuranceType
            case "start_date": f.startDate = model.0.startDate
            case "end_date": f.endDate = model.0.endDate
            case "monthly_premium_ils": f.monthlyPremiumILS = model.0.monthlyPremiumILS
            case "deductible_ils": f.deductibleILS = model.0.deductibleILS
            default: break
            }
            var e = model.1[key] ?? FieldEvidence(confidence: 0.6, evidence: "model")
            e.note = rulesHas ? "hybrid: rules value (conf \(String(format: "%.2f", conf))) replaced by model" : "hybrid: rules found nothing; model value used"
            ev[key] = e
        }
        return (f, ev)
    }
}

import Foundation

/// Canonical insurance branch. Raw strings are the Hebrew labels required by the task schema.
public enum InsuranceType: String, Codable, CaseIterable, Sendable {
    case health = "בריאות"
    case life = "חיים"
    case auto = "רכב"
    case home = "דירה"
    case pension = "פנסיה"
    // Extra branches that show up in real Israeli policies; kept so we don't
    // mis-bucket them into one of the five above.
    case longTermCare = "סיעוד"
    case personalAccident = "תאונות אישיות"
    case travel = "נסיעות לחו\"ל"
}

/// The eight target fields, exactly as the task's JSON schema names them.
public struct PolicyFields: Equatable, Sendable {
    public var insuredId: String?
    public var companyName: String?
    public var policyNumber: String?
    public var insuranceType: InsuranceType?
    public var startDate: String?          // ISO-8601 "YYYY-MM-DD"
    public var endDate: String?            // ISO-8601 "YYYY-MM-DD"
    public var monthlyPremiumILS: Double?
    public var deductibleILS: Double?

    public init(insuredId: String? = nil, companyName: String? = nil, policyNumber: String? = nil,
                insuranceType: InsuranceType? = nil, startDate: String? = nil, endDate: String? = nil,
                monthlyPremiumILS: Double? = nil, deductibleILS: Double? = nil) {
        self.insuredId = insuredId
        self.companyName = companyName
        self.policyNumber = policyNumber
        self.insuranceType = insuranceType
        self.startDate = startDate
        self.endDate = endDate
        self.monthlyPremiumILS = monthlyPremiumILS
        self.deductibleILS = deductibleILS
    }

    /// Schema key order, used for stable JSON output and for the evaluation table.
    public static let keys = [
        "insured_id", "company_name", "policy_number", "insurance_type",
        "start_date", "end_date", "monthly_premium_ils", "deductible_ils",
    ]

    /// Field values as JSON-compatible scalars keyed by schema name.
    public var jsonObject: [String: JSONValue] {
        [
            "insured_id": .from(insuredId),
            "company_name": .from(companyName),
            "policy_number": .from(policyNumber),
            "insurance_type": .from(insuranceType?.rawValue),
            "start_date": .from(startDate),
            "end_date": .from(endDate),
            "monthly_premium_ils": .from(monthlyPremiumILS),
            "deductible_ils": .from(deductibleILS),
        ]
    }
}

/// Where the text that fed the extractor came from.
public enum TextSource: String, Codable, Sendable {
    case pdfTextLayer = "pdf_text_layer"
    case tesseractOCR = "tesseract_ocr"
}

/// Per-field provenance: how sure we are and which line of the document justified the value.
public struct FieldEvidence: Equatable, Sendable {
    public var confidence: Double      // 0...1
    public var evidence: String        // the normalized line(s) the value was taken from
    public var note: String?           // e.g. "derived from annual premium / 12"

    public init(confidence: Double, evidence: String, note: String? = nil) {
        self.confidence = confidence
        self.evidence = evidence
        self.note = note
    }
}

/// Full output of the pipeline for one document.
public struct ExtractionResult: Sendable {
    public var fileName: String
    public var fields: PolicyFields
    public var evidence: [String: FieldEvidence]   // keyed by schema field name
    public var source: TextSource
    public var pageCount: Int
    public var normalizedLines: [String]
    public var timings: [String: Double]           // seconds, keyed by stage
    public var warnings: [String]

    public init(fileName: String, fields: PolicyFields, evidence: [String: FieldEvidence], source: TextSource,
                pageCount: Int, normalizedLines: [String], timings: [String: Double], warnings: [String]) {
        self.fileName = fileName
        self.fields = fields
        self.evidence = evidence
        self.source = source
        self.pageCount = pageCount
        self.normalizedLines = normalizedLines
        self.timings = timings
        self.warnings = warnings
    }
}

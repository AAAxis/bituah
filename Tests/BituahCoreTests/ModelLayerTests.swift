import XCTest
@testable import BituahCore

final class ModelLayerTests: XCTestCase {
    func testDraftValidationCanonicalizes() {
        let d = ModelDraft(insuredId: "03849201-8", companyName: "הראל חברה לביטוח בע״מ, רמת גן", policyNumber: " 7492019-24/01",
                           insuranceType: "ביטוח בריאות", startDate: "01/01/2026", endDate: "2026-12-31",
                           monthlyPremiumILS: "245.50 ש\"ח", deductibleILS: "אין")
        let (f, ev) = d.validated(modelName: "test")
        XCTAssertEqual(f.insuredId, "038492018")
        XCTAssertEqual(f.companyName, "הראל חברה לביטוח בע\"מ")
        XCTAssertEqual(f.policyNumber, "7492019-24/01")
        XCTAssertEqual(f.insuranceType, .health)
        XCTAssertEqual(f.startDate, "2026-01-01")
        XCTAssertEqual(f.endDate, "2026-12-31")
        XCTAssertEqual(f.monthlyPremiumILS, 245.5)
        XCTAssertEqual(f.deductibleILS, 0)
        XCTAssertEqual(ev.count, 8)
    }

    func testDraftValidationRejectsGarbage() {
        let d = ModelDraft(insuredId: "12", policyNumber: "01/01/2026", insuranceType: "unknown", startDate: "yesterday", monthlyPremiumILS: "10%")
        let (f, ev) = d.validated(modelName: "test")
        XCTAssertNil(f.insuredId); XCTAssertNil(f.policyNumber); XCTAssertNil(f.insuranceType)
        XCTAssertNil(f.startDate); XCTAssertNil(f.monthlyPremiumILS)
        XCTAssertTrue(ev.isEmpty)
    }

    func testHybridKeepsConfidentRulesAndFillsGaps() {
        var rules = PolicyFields(); rules.insuredId = "038492018"; rules.monthlyPremiumILS = 300
        let rulesEv = ["insured_id": FieldEvidence(confidence: 0.9, evidence: "r"), "monthly_premium_ils": FieldEvidence(confidence: 0.5, evidence: "r")]
        var model = PolicyFields(); model.insuredId = "000000000"; model.monthlyPremiumILS = 270; model.policyNumber = "123-45"
        let modelEv = ["insured_id": FieldEvidence(confidence: 0.7, evidence: "m"), "monthly_premium_ils": FieldEvidence(confidence: 0.7, evidence: "m"),
                       "policy_number": FieldEvidence(confidence: 0.7, evidence: "m")]
        let (f, ev) = HybridMerger.merge(rules: (rules, rulesEv), model: (model, modelEv), threshold: 0.8)
        XCTAssertEqual(f.insuredId, "038492018", "confident rules value kept")
        XCTAssertEqual(f.monthlyPremiumILS, 270, "low-confidence rules value replaced")
        XCTAssertEqual(f.policyNumber, "123-45", "gap filled by model")
        XCTAssertTrue(ev["policy_number"]!.note!.contains("rules found nothing"))
        XCTAssertTrue(ev["monthly_premium_ils"]!.note!.contains("replaced by model"))
    }
}

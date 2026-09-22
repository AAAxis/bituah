import XCTest
import CoreGraphics
@testable import BituahCore

private func lines(_ texts: [String]) -> [TextLine] {
    texts.enumerated().map { TextLine(text: $0.element, page: 0) }
}

final class IsraeliIDTests: XCTestCase {
    func testChecksum() {
        XCTAssertTrue(IsraeliID.isValid("123456782"))
        XCTAssertTrue(IsraeliID.isValid("000000018"))
        XCTAssertFalse(IsraeliID.isValid("123456789"))
        // The take-home fixtures are synthetic and fail the checksum — the extractor must not depend on it.
        XCTAssertFalse(IsraeliID.isValid("038492018"))
    }

    func testCanonicalPadsTo9() {
        XCTAssertEqual(IsraeliID.canonical("3849201"), "003849201")
    }

    func testChecksumIsSymmetricUnderReversal() {
        // Weights 1,2,1,2,1,2,1,2,1 are palindromic: mirroring a 9-digit ID never changes validity.
        // Consequence: the checksum cannot detect digit inversion; that is handled document-wide instead.
        for id in ["123456782", "287654321", "038492018", "059281742", "000000018"] {
            XCTAssertEqual(IsraeliID.isValid(id), IsraeliID.isValid(String(id.reversed())), id)
        }
        XCTAssertEqual(IsraeliID.candidate(from: "038492018", allowMirror: true)?.wasReversed, false)
    }
}

final class HebrewNormalizerTests: XCTestCase {
    func testDocumentLevelDigitInversion() {
        let inverted = ["מספר תעודת זהות: 810294830", "מתאריך: 6202/10/10 עד תאריך: 6202/21/13", "פרמיה חודשית 05.542 ש\"ח", "השתתפות עצמית 005,1 ש\"ח"]
        XCTAssertTrue(HebrewNormalizer.digitsLookInverted(inverted))
        let normal = ["מספר תעודת זהות: 038492018", "מתאריך: 01/01/2026 עד תאריך: 31/12/2026", "פרמיה חודשית 245.50 ש\"ח"]
        XCTAssertFalse(HebrewNormalizer.digitsLookInverted(normal))
        let fixed = HebrewNormalizer.normalize(inverted.map { TextLine(text: $0, page: 0) })
        XCTAssertEqual(fixed[0].text, "מספר תעודת זהות: 038492018")
        XCTAssertEqual(fixed[2].text, "פרמיה חודשית 245.50 ש\"ח")
        XCTAssertTrue(fixed.allSatisfy(\.wasReversed))
    }

    func testCharacterCleanup() {
        XCTAssertEqual(HebrewNormalizer.cleanCharacters("בע״מ\u{200F} \u{00A0} 1,500 ש״ח"), "בע\"מ 1,500 ש\"ח")
        XCTAssertEqual(HebrewNormalizer.cleanCharacters("שָׁלוֹם"), "שלום")
        XCTAssertEqual(HebrewNormalizer.cleanCharacters("01/01/2026 – 31/12/2026"), "01/01/2026 - 31/12/2026")
    }

    func testFullReverseRepair() {
        let visual = "038492018 :תוהז תדועת רפסמ"
        let r = HebrewNormalizer.repairOrder(visual)
        XCTAssertTrue(r.reversed)
        XCTAssertEqual(r.text, "מספר תעודת זהות: 038492018")
    }

    func testFullReverseKeepsDatesAndPolicyNumbers() {
        let visual = "31/12/2026 :ךיראת דע 01/01/2026 :ךיראתמ חוטיבה תפוקת"
        XCTAssertEqual(HebrewNormalizer.repairOrder(visual).text, "תקופת הביטוח מתאריך: 01/01/2026 עד תאריך: 31/12/2026")
        XCTAssertEqual(HebrewNormalizer.repairOrder("7492019-24/01 הסילופ רפסמ").text, "מספר פוליסה 7492019-24/01")
    }

    func testPerWordRepair() {
        XCTAssertEqual(HebrewNormalizer.repairOrder("הימרפ תישדוח םולשתל 245.50").text, "פרמיה חודשית לתשלום 245.50")
    }

    func testLogicalLinesUntouched() {
        for s in ["מספר פוליסה 7492019-24/01", "Harel Insurance Co. | Form 402-A", "שם המבוטח: דנה כהן"] {
            XCTAssertFalse(HebrewNormalizer.repairOrder(s).reversed, s)
        }
    }

    func testRowMergeIsRightToLeft() {
        let label = TextLine(text: "מספר פוליסה", page: 0, bbox: CGRect(x: 484, y: 555, width: 70, height: 12))
        let value = TextLine(text: "7492019-24/01", page: 0, bbox: CGRect(x: 293, y: 556, width: 80, height: 12))
        let merged = HebrewNormalizer.normalize([label, value])
        XCTAssertEqual(merged.map(\.text), ["מספר פוליסה 7492019-24/01"])
    }
}

final class DateParserTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(DateParser.all(in: "31/12/2026").first?.iso, "2026-12-31")
        XCTAssertEqual(DateParser.all(in: "31.12.26").first?.iso, "2026-12-31")
        XCTAssertEqual(DateParser.all(in: "2026-12-31").first?.iso, "2026-12-31")
        XCTAssertEqual(DateParser.all(in: "1 בינואר 2026").first?.iso, "2026-01-01")
    }

    func testReversedDigits() {
        let f = DateParser.all(in: "6202/21/13").first
        XCTAssertEqual(f?.iso, "2026-12-31")
        XCTAssertEqual(f?.wasReversed, true)
    }

    func testInvalid() {
        XCTAssertTrue(DateParser.all(in: "31/02/2026").isEmpty)
        XCTAssertTrue(DateParser.all(in: "32/13/2026").isEmpty)
    }
}

final class AmountParserTests: XCTestCase {
    func testAmounts() {
        let a = AmountParser.all(in: "1,500 ש\"ח")
        XCTAssertEqual(a.first?.value, 1500)
        XCTAssertEqual(a.first?.hasCurrency, true)
        XCTAssertEqual(AmountParser.all(in: "₪245.50").first?.value, 245.5)
        XCTAssertEqual(AmountParser.all(in: "15%").first?.isPercent, true)
        XCTAssertTrue(AmountParser.mentionsZero("אין (0 ש\"ח)"))
        XCTAssertTrue(AmountParser.mentionsZero("ללא השתתפות"))
    }

    func testDateTokenDetection() {
        XCTAssertTrue(AmountParser.looksLikeDate("01/01/2026"))
        XCTAssertFalse(AmountParser.looksLikeDate("7492019-24/01"))   // policy number, not a date
    }
}

final class FieldExtractorTests: XCTestCase {
    func testSeparateRows() {
        let (f, ev) = PolicyParser.extract(from: lines([
            "הראל חברה לביטוח בע\"מ",
            "מספר תעודת זהות: 038492018",
            "מספר פוליסה", "7492019-24/01",
            "סוג ענף ביטוח", "ביטוח בריאות פרטי",
            "תקופת הביטוח", "מתאריך: 01/01/2026 עד תאריך: 31/12/2026",
            "השתתפות עצמית בפועל", "1,500 ש\"ח",
            "פרמיה חודשית לתשלום", "245.50 ש\"ח",
            "המסמך הופק בתאריך 02/01/2026",
        ]))
        XCTAssertEqual(f.insuredId, "038492018")
        XCTAssertEqual(f.policyNumber, "7492019-24/01")
        XCTAssertEqual(f.companyName, "הראל חברה לביטוח בע\"מ")
        XCTAssertEqual(f.insuranceType, .health)
        XCTAssertEqual(f.startDate, "2026-01-01")
        XCTAssertEqual(f.endDate, "2026-12-31")
        XCTAssertEqual(f.monthlyPremiumILS, 245.5)
        XCTAssertEqual(f.deductibleILS, 1500)
        XCTAssertEqual(ev.count, 8)
    }

    func testInlineLabels() {
        let (f, _) = PolicyParser.extract(from: lines([
            "מגדל חברה לביטוח בע\"מ - רשימת פוליסה",
            "ת.ז: 059281742  מס' פוליסה: 9102845-26",
            "ענף: רכב",
            "תקופת ביטוח: 15/03/2026 - 14/03/2027",
            "פרמיה חודשית: ₪380",
            "השתתפות עצמית: 1,200 ש\"ח",
        ]))
        XCTAssertEqual(f.insuredId, "059281742")
        XCTAssertEqual(f.policyNumber, "9102845-26")
        XCTAssertEqual(f.insuranceType, .auto)
        XCTAssertEqual(f.startDate, "2026-03-15")
        XCTAssertEqual(f.endDate, "2027-03-14")
        XCTAssertEqual(f.monthlyPremiumILS, 380)
        XCTAssertEqual(f.deductibleILS, 1200)
    }

    func testLabelledIdBeatsNearbyPlateNumber() {
        let (f, _) = PolicyParser.extract(from: lines([
            "מספר תעודת זהות: 059281742",
            "מספר רישוי רכב: 824-91-302",
        ]))
        XCTAssertEqual(f.insuredId, "059281742")
    }

    func testAnnualPremiumDerived() {
        let (f, ev) = PolicyParser.extract(from: lines(["פרמיה שנתית", "2,946 ש\"ח"]))
        XCTAssertEqual(f.monthlyPremiumILS, 245.5)
        XCTAssertNotNil(ev["monthly_premium_ils"]?.note)
    }

    func testNoDeductibleVariants() {
        XCTAssertEqual(PolicyParser.extract(from: lines(["השתתפות עצמית", "אין (0 ש\"ח)"])).0.deductibleILS, 0)
        XCTAssertEqual(PolicyParser.extract(from: lines(["השתתפות עצמית: ללא"])).0.deductibleILS, 0)
        let pct = PolicyParser.extract(from: lines(["השתתפות עצמית", "10%"]))
        XCTAssertNil(pct.0.deductibleILS)
        XCTAssertNotNil(pct.1["deductible_ils"]?.note)
        XCTAssertNil(PolicyParser.extract(from: lines(["פרמיה חודשית 100 ש\"ח"])).0.deductibleILS)
    }

    func testPensionSideMentionDoesNotOverrideLife() {
        let (f, _) = PolicyParser.extract(from: lines([
            "סוג ביטוח", "ביטוח חיים (ריסק למוות מכל סיבה)",
            "פוליסה מסוג ריסק טהור ללא צבירת חיסכון פנסיוני.",
        ]))
        XCTAssertEqual(f.insuranceType, .life)
    }

    func testCompanyNameTidy() {
        XCTAssertEqual(PolicyParser.extract(from: lines(["שם חברת הביטוח", "מגדל חברה לביטוח בע\"מ, פתח תקווה"])).0.companyName,
                       "מגדל חברה לביטוח בע\"מ")
        XCTAssertEqual(PolicyParser.extract(from: lines(["הודעה ללקוחות מנורה"])).0.companyName, "מנורה מבטחים ביטוח בע\"מ")
    }

    func testIssueDateIgnoredAndSwappedPeriodReordered() {
        let (f, ev) = PolicyParser.extract(from: lines([
            "תקופת הביטוח", "31/05/2036 - 01/06/2026",
            "המסמך הופק בתאריך 02/01/2026",
        ]))
        XCTAssertEqual(f.startDate, "2026-06-01")
        XCTAssertEqual(f.endDate, "2036-05-31")
        XCTAssertNotNil(ev["start_date"]?.note)
    }
}

final class MetricsTests: XCTestCase {
    func testRates() {
        XCTAssertEqual(Metrics.cer(reference: "abc", hypothesis: "abd"), 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(Metrics.wer(reference: "מספר פוליסה 123", hypothesis: "מספר פוליסה"), 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(Metrics.cer(reference: "ש״ח", hypothesis: "ש\"ח"), 0)   // normalization applied to both
    }

    func testJSONNumberStyle() {
        XCTAssertEqual(JSONValue.number(1500).serialized(), "1500.0")
        XCTAssertEqual(JSONValue.number(245.5).serialized(), "245.5")
        XCTAssertEqual(JSONValue.string("בע\"מ").serialized(), "\"בע\\\"מ\"")
    }
}

final class OCRFusionTests: XCTestCase {
    func testVisionTokenReplacesGarbageOnSameRow() {
        let row = CGRect(x: 300, y: 500, width: 250, height: 12)
        let primary = [TextLine(text: "מספר פוליסה 731", page: 0, bbox: row, confidence: 0.6, words: [
            TextWord(text: "מספר", bbox: CGRect(x: 520, y: 500, width: 30, height: 12)),
            TextWord(text: "פוליסה", bbox: CGRect(x: 480, y: 500, width: 38, height: 12)),
            TextWord(text: "731", bbox: CGRect(x: 300, y: 500, width: 40, height: 12)),
        ])]
        let numeric = [TextLine(text: "7492019-24/01", page: 0, bbox: CGRect(x: 295, y: 499, width: 80, height: 13), words: [
            TextWord(text: "7492019-24/01", bbox: CGRect(x: 295, y: 499, width: 80, height: 13)),
        ])]
        let fused = OCRFusion.fuse(primary: primary, numeric: numeric)
        XCTAssertEqual(fused.lines.first?.text, "מספר פוליסה 7492019-24/01")
        XCTAssertEqual(fused.replacedTokens, 1)
    }
}

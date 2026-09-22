import Foundation
import PDFKit

public struct ParserOptions {
    /// Skip the text layer and OCR every page (used to benchmark the OCR tier on digital PDFs).
    public var forceOCR = false
    /// Render resolution for OCR. 300 dpi is Tesseract's sweet spot; 200 is ~2× faster on a phone.
    public var dpi: CGFloat = 300
    /// OCR engine for image-only pages. nil = text layer only.
    public var ocrEngine: OCREngine?
    /// Secondary engine used to cross-check digit strings (Vision on Apple platforms).
    public var digitCrossCheckEngine: OCREngine?
    /// rules (default) | model | hybrid — see `ExtractionMode`.
    public var mode: ExtractionMode = .rules
    /// On-device language model used by `.model` and `.hybrid`.
    public var fieldModel: FieldModel?
    /// Hybrid: rules values with confidence below this are replaced by the model's.
    public var hybridThreshold: Double = 0.8

    public init(forceOCR: Bool = false, dpi: CGFloat = 300, ocrEngine: OCREngine? = nil, digitCrossCheckEngine: OCREngine? = nil) {
        self.forceOCR = forceOCR
        self.dpi = dpi
        self.ocrEngine = ocrEngine
        self.digitCrossCheckEngine = digitCrossCheckEngine
    }
}

/// End-to-end: PDF → lines (text layer, else OCR) → Hebrew normalization → field extraction.
public final class PolicyParser {
    public let options: ParserOptions

    public init(options: ParserOptions = ParserOptions()) {
        self.options = options
    }

    public func parse(url: URL) throws -> ExtractionResult {
        guard let doc = PDFDocument(url: url) else {
            throw OCRError("cannot open PDF: \(url.path)")
        }
        return try parse(document: doc, fileName: url.lastPathComponent)
    }

    public func parse(document doc: PDFDocument, fileName: String) throws -> ExtractionResult {
        var timings: [String: Double] = [:]
        var warnings: [String] = []
        let t0 = Date()

        // Tier 1: native text layer.
        var pages = options.forceOCR ? [] : PDFTextLayerExtractor().extract(document: doc)
        timings["text_layer"] = Date().timeIntervalSince(t0)
        var source: TextSource = .pdfTextLayer

        // Tier 2: OCR for pages without a usable layer.
        var lines: [TextLine] = []
        var ocrSeconds = 0.0
        var digitSeconds = 0.0
        var fusedCount = 0
        for i in 0..<doc.pageCount {
            let existing = pages.first { $0.index == i }
            if let p = existing, PDFTextLayerExtractor.hasUsableText(p) {
                lines += p.lines
                continue
            }
            guard let engine = options.ocrEngine, let page = doc.page(at: i) else {
                warnings.append("page \(i + 1): no text layer and no OCR engine configured")
                continue
            }
            let t1 = Date()
            guard let raster = PageRasterizer.render(page: page, dpi: options.dpi) else {
                warnings.append("page \(i + 1): rasterization failed"); continue
            }
            do {
                var ocrLines = try engine.recognize(image: raster.image, pageIndex: i, scale: raster.scale, pageHeight: raster.pageBounds.height)
                ocrSeconds += Date().timeIntervalSince(t1)
                source = .tesseractOCR
                if let cc = options.digitCrossCheckEngine {
                    let t2 = Date()
                    if let digitLines = try? cc.recognize(image: raster.image, pageIndex: i, scale: raster.scale, pageHeight: raster.pageBounds.height) {
                        let fused = OCRFusion.fuse(primary: ocrLines, numeric: digitLines)
                        fusedCount += fused.replacedTokens
                        ocrLines = fused.lines
                    }
                    digitSeconds += Date().timeIntervalSince(t2)
                }
                lines += ocrLines
                if existing == nil {
                    pages.append(PageText(index: i, lines: ocrLines, rawText: ocrLines.map(\.text).joined(separator: "\n")))
                }
            } catch {
                warnings.append("page \(i + 1): OCR failed: \(error)")
                ocrSeconds += Date().timeIntervalSince(t1)
            }
        }
        if ocrSeconds > 0 { timings["ocr_primary"] = ocrSeconds }
        if digitSeconds > 0 { timings["ocr_digits"] = digitSeconds }
        if fusedCount > 0 { warnings.append("\(fusedCount) numeric token(s) taken from the digit engine (Vision) by position") }

        // Normalize.
        let t2 = Date()
        let normalized = HebrewNormalizer.normalize(lines)
        let reversedCount = normalized.filter(\.wasReversed).count
        if reversedCount > 0 { warnings.append("\(reversedCount) line(s) had reversed (visual-order) text or inverted digits and were repaired") }
        timings["normalize"] = Date().timeIntervalSince(t2)

        // Extract.
        let t3 = Date()
        var (fields, evidence) = Self.extract(from: normalized)
        timings["extract"] = Date().timeIntervalSince(t3)
        if options.mode != .rules {
            let t4 = Date()
            if let model = options.fieldModel {
                do {
                    let draft = try model.extract(lines: normalized.map(\.text))
                    let validated = draft.validated(modelName: model.name)
                    switch options.mode {
                    case .model: (fields, evidence) = validated
                    case .hybrid: (fields, evidence) = HybridMerger.merge(rules: (fields, evidence), model: validated, threshold: options.hybridThreshold)
                    case .rules: break
                    }
                } catch {
                    warnings.append("model failed: \(error)")
                    if options.mode == .model { fields = PolicyFields(); evidence = [:] }
                }
            } else {
                warnings.append("mode \(options.mode.rawValue) requested but no model configured")
                if options.mode == .model { fields = PolicyFields(); evidence = [:] }
            }
            timings["model"] = Date().timeIntervalSince(t4)
        }
        timings["total"] = Date().timeIntervalSince(t0)

        return ExtractionResult(fileName: fileName, fields: fields, evidence: evidence, source: source,
                                pageCount: doc.pageCount, normalizedLines: normalized.map(\.text),
                                timings: timings, warnings: warnings)
    }

    /// Pure function over normalized lines — this is what the unit tests exercise.
    public static func extract(from lines: [TextLine]) -> (PolicyFields, [String: FieldEvidence]) {
        let x = FieldExtractor(lines: lines)
        var f = PolicyFields()
        var ev: [String: FieldEvidence] = [:]

        if let (v, e) = x.insuredId() { f.insuredId = v; ev["insured_id"] = e }
        if let (v, e) = x.companyName() { f.companyName = v; ev["company_name"] = e }
        if let (v, e) = x.policyNumber(excluding: f.insuredId) { f.policyNumber = v; ev["policy_number"] = e }
        if let (v, e) = x.insuranceType() { f.insuranceType = v; ev["insurance_type"] = e }
        let p = x.period()
        if let (v, e) = p.start { f.startDate = v; ev["start_date"] = e }
        if let (v, e) = p.end { f.endDate = v; ev["end_date"] = e }
        if let (v, e) = x.monthlyPremium() { f.monthlyPremiumILS = v; ev["monthly_premium_ils"] = e }
        if let (v, e) = x.deductible() { f.deductibleILS = v; ev["deductible_ils"] = e }
        return (f, ev)
    }

}

import Foundation
#if canImport(FoundationModels)
import FoundationModels

/// Apple's on-device language model (Foundation Models framework, iOS 26 / macOS 26+).
/// Weights are system-managed (~3B parameters, loaded by a system service, shared across apps),
/// nothing leaves the device, and guided generation guarantees the output shape.
/// Hebrew is not an officially supported locale (`supportsLocale(he_IL)` is false); it is used here
/// precisely to measure how far that gets on real Hebrew policy text.
@available(macOS 26, iOS 26, *)
public final class FoundationModelExtractor: FieldModel {
    public let name = "apple-foundation-model"

    @Generable
    struct Draft {
        // Required strings: optional properties were frequently skipped by the model. "" means absent.
        @Guide(description: "Israeli ID number of the insured (מספר תעודת זהות / ת.ז), digits only, usually 9 digits; empty string if absent")
        var insuredId: String
        @Guide(description: "Insurance company legal name exactly as written in the text (e.g. הראל חברה לביטוח בע״מ); empty string if absent")
        var companyName: String
        @Guide(description: "Policy number (מספר פוליסה) exactly as written, may contain - or /; empty string if absent")
        var policyNumber: String
        @Guide(description: "Insurance branch", .anyOf(["בריאות", "חיים", "רכב", "דירה", "פנסיה", "סיעוד", "תאונות אישיות", "נסיעות לחו״ל", ""]))
        var insuranceType: String
        @Guide(description: "Insurance period start date (תקופת הביטוח, מתאריך) as YYYY-MM-DD; empty string if absent")
        var startDate: String
        @Guide(description: "Insurance period end date (עד תאריך) as YYYY-MM-DD; empty string if absent")
        var endDate: String
        @Guide(description: "Monthly premium in shekels (פרמיה חודשית) as a plain number like 245.50; empty string if absent")
        var monthlyPremiumILS: String
        @Guide(description: "Deductible in shekels (השתתפות עצמית) as a plain number; 0 if the text says אין or ללא; empty string if absent")
        var deductibleILS: String
    }

    static let instructions = """
    You extract fields from Israeli insurance policy documents written in Hebrew.
    The user message contains the document text, one line per row, in logical reading order.
    Copy values exactly from the text. Do not invent values: leave a field empty if it is not in the text.
    Dates in the text are day/month/year; convert them to YYYY-MM-DD.
    Ignore document issue dates (הופק, הודפס) — the period is the one after תקופת הביטוח / מתאריך / עד תאריך.
    The monthly premium is the value next to פרמיה חודשית; the deductible next to השתתפות עצמית.
    """

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public var availabilityDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let reason): return "unavailable: \(reason)"
        }
    }

    public init() {}

    public func extract(lines: [String]) throws -> ModelDraft {
        guard isAvailable else { throw OCRError("Apple Foundation Model unavailable: \(availabilityDescription)") }
        // ASCII quotes inside values (בע"מ) terminate guided strings; hand the model Hebrew gershayim/geresh
        // instead. The normalizer folds them back to ASCII on the way out.
        var text = lines.joined(separator: "\n").replacingOccurrences(of: "\"", with: "״").replacingOccurrences(of: "'", with: "׳")
        if text.count > 3500 { text = String(text.prefix(3500)) }   // stay inside the 4k-token context
        let session = LanguageModelSession(instructions: Self.instructions)
        let options = GenerationOptions(sampling: .greedy)
        // Bridge async guided generation into the synchronous pipeline.
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let r = try await session.respond(to: "Document text:\n\(text)", generating: Draft.self, options: options)
                box.result = .success(r.content)
            } catch {
                box.result = .failure(error)
            }
            sem.signal()
        }
        sem.wait()
        switch box.result! {
        case .failure(let e): throw OCRError("foundation model: \(e)")
        case .success(let d):
            func v(_ s: String) -> String? { s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s }
            return ModelDraft(insuredId: v(d.insuredId), companyName: v(d.companyName), policyNumber: v(d.policyNumber),
                              insuranceType: v(d.insuranceType), startDate: v(d.startDate), endDate: v(d.endDate),
                              monthlyPremiumILS: v(d.monthlyPremiumILS), deductibleILS: v(d.deductibleILS),
                              rawText: "\(d)")
        }
    }

    final class ResultBox: @unchecked Sendable { var result: Result<Draft, Error>? }
}
#endif

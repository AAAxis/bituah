import Foundation
import BituahCore

/// A parsed policy kept on the device (Documents/history.json). Nothing leaves the phone.
struct HistoryEntry: Identifiable, Codable, Equatable {
    struct Evidence: Codable, Equatable { var confidence: Double; var evidence: String; var note: String? }
    var id: UUID
    var date: Date
    var title: String
    var source: String
    var pages: Int
    var totalMs: Int
    var fieldsJSON: String
    var evidence: [String: Evidence]
    var warnings: [String]
    var lines: [String]

    init(result r: ExtractionResult, title: String) {
        id = UUID(); date = Date(); self.title = title
        source = r.source.rawValue; pages = r.pageCount
        totalMs = Int((r.timings["total"] ?? 0) * 1000)
        fieldsJSON = JSONValue.object(PolicyFields.keys.map { ($0, r.fields.jsonObject[$0] ?? .null) }).serialized(pretty: false)
        evidence = r.evidence.mapValues { Evidence(confidence: $0.confidence, evidence: $0.evidence, note: $0.note) }
        warnings = r.warnings
        lines = r.normalizedLines
    }

    var fields: JSONValue { (try? JSONValue.parse(data: Data(fieldsJSON.utf8))) ?? .null }
    func value(_ key: String) -> JSONValue? { fields[key] }
    var companyName: String { value("company_name")?.stringValue ?? "—" }
    var insuranceType: String { value("insurance_type")?.stringValue ?? "—" }
    var premium: String {
        guard let d = value("monthly_premium_ils")?.doubleValue else { return "—" }
        return "₪" + (d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.2f", d))
    }
    var filledCount: Int { PolicyFields.keys.filter { value($0) != nil && value($0) != .null }.count }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    private let url: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = docs.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        persist()
    }

    func delete(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        persist()
    }

    func clear() { entries.removeAll(); persist() }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}

import SwiftUI
import BituahCore

struct ResultView: View {
    let entry: HistoryEntry

    private static let labels: [(String, String)] = [
        ("insured_id", "ת.ז המבוטח"), ("company_name", "חברת הביטוח"), ("policy_number", "מספר פוליסה"),
        ("insurance_type", "סוג ביטוח"), ("start_date", "תחילת ביטוח"), ("end_date", "תום ביטוח"),
        ("monthly_premium_ils", "פרמיה חודשית (₪)"), ("deductible_ils", "השתתפות עצמית (₪)"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.labels, id: \.0) { key, label in
                    FieldRow(label: label, value: display(entry.value(key)), evidence: entry.evidence[key])
                }
            } header: {
                Text("שדות שחולצו")
            } footer: {
                Text("\(entry.source == "tesseract_ocr" ? "OCR" : "שכבת טקסט") · \(entry.pages) עמ׳ · \(entry.totalMs) ms · הכל על המכשיר")
            }
            if !entry.warnings.isEmpty {
                Section("הערות") { ForEach(entry.warnings, id: \.self) { Text($0).font(.caption) } }
            }
            Section("טקסט מזוהה (\(entry.lines.count) שורות)") {
                ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: entry.fields.serialized(), preview: SharePreview("result.json")) { Image(systemName: "square.and.arrow.up") }
        }
    }

    private func display(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s): return s
        case .number(let d): return d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.2f", d)
        default: return "—"
        }
    }
}

struct FieldRow: View {
    let label: String
    let value: String
    let evidence: HistoryEntry.Evidence?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let e = evidence { ConfidenceBadge(value: e.confidence) }
            }
            Text(value).font(.body.weight(.semibold)).textSelection(.enabled)
            if let e = evidence {
                Text(e.evidence).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                if let n = e.note { Text(n).font(.caption2).foregroundStyle(.orange) }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ConfidenceBadge: View {
    let value: Double
    var body: some View {
        Text(String(format: "%.0f%%", value * 100))
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(value >= 0.8 ? Color.green.opacity(0.2) : (value >= 0.5 ? Color.yellow.opacity(0.25) : Color.red.opacity(0.2)))
            .clipShape(Capsule())
    }
}

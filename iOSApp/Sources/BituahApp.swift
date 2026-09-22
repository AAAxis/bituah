import SwiftUI
import BituahCore

/// iOS front-end over BituahCore. On iOS only the PDFKit text-layer tier runs (Tesseract is not
/// linked in this demo); image-only pages report a warning instead of a value.
@main
struct BituahApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack { ContentView() }
                .environment(\.layoutDirection, .rightToLeft)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var result: ExtractionResult?
    @Published var error: String?
    @Published var isRunning = false

    var bundledSamples: [URL] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "pdf", subdirectory: "Samples") ?? Bundle.main.urls(forResourcesWithExtension: "pdf", subdirectory: nil) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func run(url: URL) {
        isRunning = true
        error = nil
        result = nil
        Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let outcome = Result { try PolicyParser(options: ParserOptions()).parse(url: url) }
            await MainActor.run {
                switch outcome {
                case .success(let r): self.result = r
                case .failure(let e): self.error = "\(e)"
                }
                self.isRunning = false
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showPicker = false

    private static let labels: [(String, String)] = [
        ("insured_id", "ת.ז המבוטח"), ("company_name", "חברת הביטוח"), ("policy_number", "מספר פוליסה"),
        ("insurance_type", "סוג ביטוח"), ("start_date", "תחילת ביטוח"), ("end_date", "תום ביטוח"),
        ("monthly_premium_ils", "פרמיה חודשית (₪)"), ("deductible_ils", "השתתפות עצמית (₪)"),
    ]

    var body: some View {
        List {
            Section("פוליסות לדוגמה") {
                ForEach(model.bundledSamples, id: \.self) { url in
                    Button {
                        model.run(url: url)
                    } label: {
                        Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc.text")
                    }
                }
                Button { showPicker = true } label: { Label("בחר PDF מהקבצים…", systemImage: "folder") }
            }
            if model.isRunning { Section { ProgressView("מעבד על המכשיר…") } }
            if let err = model.error { Section { Text(err).foregroundStyle(.red) } }
            if let r = model.result {
                let values = r.fields.jsonObject
                Section {
                    ForEach(Self.labels, id: \.0) { key, label in
                        FieldRow(label: label, value: display(values[key]), evidence: r.evidence[key])
                    }
                } header: {
                    Text("שדות שחולצו")
                } footer: {
                    Text("\(r.source == .pdfTextLayer ? "שכבת טקסט" : "OCR") · \(Int((r.timings["total"] ?? 0) * 1000)) ms · הכל על המכשיר, ללא ענן")
                }
                if !r.warnings.isEmpty {
                    Section("הערות") { ForEach(r.warnings, id: \.self) { Text($0).font(.caption) } }
                }
                Section("טקסט מנורמל (\(r.normalizedLines.count) שורות)") {
                    ForEach(Array(r.normalizedLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle("חילוץ שדות מפוליסה")
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf]) { res in
            if case .success(let url) = res { model.run(url: url) }
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
    let evidence: FieldEvidence?

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

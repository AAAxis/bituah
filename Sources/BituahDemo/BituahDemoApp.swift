import SwiftUI
import BituahCore

/// Minimal SwiftUI front-end over BituahCore (macOS here; the views are plain SwiftUI and compile for iOS).
/// Shows the eight fields in a right-to-left form with a confidence badge and the evidence line per field.
@main
struct BituahDemoApp: App {
    var body: some Scene {
        WindowGroup("ביטוח — חילוץ שדות מפוליסה") {
            ContentView()
                .environment(\.layoutDirection, .rightToLeft)
                .frame(minWidth: 720, minHeight: 560)
        }
    }
}

@MainActor
final class DemoModel: ObservableObject {
    @Published var result: ExtractionResult?
    @Published var error: String?
    @Published var isRunning = false
    @Published var forceOCR = false

    func run(url: URL) {
        isRunning = true
        error = nil
        let force = forceOCR
        Task.detached(priority: .userInitiated) {
            var opts = ParserOptions(forceOCR: force)
            #if os(macOS)
            let tess = TesseractCLIEngine()
            if tess.isAvailable { opts.ocrEngine = tess; opts.digitCrossCheckEngine = VisionOCREngine() }
            #endif
            let outcome = Result { try PolicyParser(options: opts).parse(url: url) }
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
    @StateObject private var model = DemoModel()
    @State private var showPicker = false

    private static let labels: [(String, String)] = [
        ("insured_id", "ת.ז המבוטח"), ("company_name", "חברת הביטוח"), ("policy_number", "מספר פוליסה"),
        ("insurance_type", "סוג ביטוח"), ("start_date", "תחילת ביטוח"), ("end_date", "תום ביטוח"),
        ("monthly_premium_ils", "פרמיה חודשית (₪)"), ("deductible_ils", "השתתפות עצמית (₪)"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("בחר קובץ PDF…") { showPicker = true }
                    .keyboardShortcut("o")
                Toggle("OCR בכוח", isOn: $model.forceOCR)
                Spacer()
                if model.isRunning { ProgressView().controlSize(.small) }
                if let r = model.result {
                    Text(r.source == .pdfTextLayer ? "שכבת טקסט" : "OCR")
                        .font(.caption).padding(4).background(.quaternary).cornerRadius(4)
                    Text(String(format: "%.0f ms", (r.timings["total"] ?? 0) * 1000)).font(.caption).monospacedDigit()
                }
            }
            .padding()

            Divider()

            if let err = model.error {
                Text(err).foregroundStyle(.red).padding()
            }

            if let r = model.result {
                let values = r.fields.jsonObject
                List {
                    Section("שדות שחולצו") {
                        ForEach(Self.labels, id: \.0) { key, label in
                            FieldRow(label: label, value: display(values[key]), evidence: r.evidence[key])
                        }
                    }
                    if !r.warnings.isEmpty {
                        Section("הערות") { ForEach(r.warnings, id: \.self) { Text($0).font(.caption) } }
                    }
                    Section("טקסט מנורמל (\(r.normalizedLines.count) שורות)") {
                        ForEach(Array(r.normalizedLines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            } else if !model.isRunning {
                ContentUnavailableView("גררו או בחרו פוליסה בפורמט PDF", systemImage: "doc.text.magnifyingglass",
                                       description: Text("העיבוד מתבצע במלואו על המכשיר — שום נתון לא נשלח לענן."))
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf]) { res in
            if case .success(let url) = res { model.run(url: url) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url = url { Task { @MainActor in model.run(url: url) } }
            }
            return true
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
                Text(label).font(.subheadline).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                Text(value).font(.body.weight(.semibold)).textSelection(.enabled)
                Spacer()
                if let e = evidence { ConfidenceBadge(value: e.confidence) }
            }
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

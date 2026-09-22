import SwiftUI
import PDFKit
import BituahCore

@MainActor
final class ScanModel: ObservableObject {
    @Published var isRunning = false
    @Published var status = ""
    @Published var error: String?
    @Published var lastEntry: HistoryEntry?

    var bundledSamples: [URL] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "pdf", subdirectory: "Samples") ?? []
        let variants = Bundle.main.urls(forResourcesWithExtension: "pdf", subdirectory: "Samples/variants") ?? []
        return (urls + variants).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func options() -> ParserOptions {
        var o = ParserOptions()
        o.ocrEngine = TesseractiOSEngine.shared
        o.digitCrossCheckEngine = VisionOCREngine()
        return o
    }

    func parse(url: URL, history: HistoryStore) {
        run(title: url.deletingPathExtension().lastPathComponent, history: history) { opts in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            return try PolicyParser(options: opts).parse(url: url)
        }
    }

    /// Camera pages → PDF in memory → the same pipeline with OCR forced.
    func parse(images: [UIImage], history: HistoryStore) {
        let doc = PDFDocument()
        for (i, img) in images.enumerated() {
            let scaled = img.downscaled(maxSide: 2600)
            if let page = PDFPage(image: scaled) { doc.insert(page, at: i) }
        }
        let title = "צילום " + Date().formatted(date: .abbreviated, time: .shortened)
        run(title: title, history: history) { opts in
            var o = opts
            o.forceOCR = true
            o.dpi = 72   // page points == image pixels after PDFPage(image:), so no re-scaling
            return try PolicyParser(options: o).parse(document: doc, fileName: title)
        }
    }

    private func run(title: String, history: HistoryStore, _ work: @escaping (ParserOptions) throws -> ExtractionResult) {
        isRunning = true; error = nil; status = "מעבד על המכשיר…"
        let opts = options()
        Task.detached(priority: .userInitiated) {
            let outcome = Result { try work(opts) }
            await MainActor.run {
                switch outcome {
                case .success(let r):
                    let entry = HistoryEntry(result: r, title: title)
                    history.add(entry)
                    self.lastEntry = entry
                case .failure(let e): self.error = "\(e)"
                }
                self.isRunning = false
            }
        }
    }
}

extension UIImage {
    func downscaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height) * scale
        guard longest > maxSide else { return self }
        let f = maxSide / longest
        let newSize = CGSize(width: size.width * scale * f, height: size.height * scale * f)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

struct ScanView: View {
    @EnvironmentObject private var history: HistoryStore
    @StateObject private var model = ScanModel()
    @State private var showCamera = false
    @State private var showPicker = false
    @State private var showResult = false
    @State private var showSamples = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.tint)
            Text("צלמו את הפוליסה")
                .font(.title2.weight(.semibold))
            Text("הזיהוי מתבצע במלואו על המכשיר.\nשום נתון לא נשלח לענן.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()

            if model.isRunning {
                ProgressView(model.status).padding()
            } else if let err = model.error {
                Text(err).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
            }

            Button {
                showCamera = true
            } label: {
                Label("צלם פוליסה", systemImage: "camera.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isRunning || !DocumentScanner.isSupported)
            .padding(.horizontal)

            HStack(spacing: 16) {
                Button { showPicker = true } label: { Label("ייבוא PDF", systemImage: "folder") }
                Button { showSamples = true } label: { Label("דוגמאות", systemImage: "doc.on.doc") }
            }
            .buttonStyle(.bordered)
            .disabled(model.isRunning)
            .padding(.bottom, 24)
        }
        .navigationTitle("ביטוח")
        .fullScreenCover(isPresented: $showCamera) {
            DocumentScanner { images in model.parse(images: images, history: history) }
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showSamples) {
            NavigationStack {
                List(model.bundledSamples, id: \.self) { url in
                    Button {
                        showSamples = false
                        model.parse(url: url, history: history)
                    } label: {
                        Label(url.deletingPathExtension().lastPathComponent,
                              systemImage: url.lastPathComponent.hasPrefix("scan_") ? "doc.viewfinder" : "doc.text")
                    }
                }
                .navigationTitle("פוליסות לדוגמה")
                .navigationBarTitleDisplayMode(.inline)
            }
            .environment(\.layoutDirection, .rightToLeft)
            .presentationDetents([.medium])
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf]) { res in
            if case .success(let url) = res { model.parse(url: url, history: history) }
        }
        .onChange(of: model.lastEntry) { _, entry in if entry != nil { showResult = true } }
        .navigationDestination(isPresented: $showResult) {
            if let e = model.lastEntry { ResultView(entry: e) }
        }
    }
}

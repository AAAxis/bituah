import Foundation
import CoreGraphics

#if os(macOS)
/// Tesseract 5 with the `heb` model, driven through the command-line binary.
///
/// Why a subprocess and not libtesseract linked in: the take-home is a CLI on macOS, and the
/// subprocess keeps the package dependency-free (`swift build` needs nothing but Xcode).
/// On iOS the same engine is linked statically (libtesseract + libleptonica as an xcframework,
/// e.g. SwiftyTesseract) and exposed through this exact `OCREngine` protocol — the pipeline
/// code above it does not change.
public struct TesseractCLIEngine: OCREngine {
    public let name = "tesseract"
    public var binary: URL
    public var languages: String
    /// Page segmentation mode. 4 = "assume a single column of text of variable sizes" works best
    /// for label/value forms; 6 = uniform block; 3 = fully automatic.
    public var psm: Int

    public init(binary: URL? = nil, languages: String = "heb+eng", psm: Int = 4) {
        self.binary = binary ?? Self.locateBinary() ?? URL(fileURLWithPath: "/opt/homebrew/bin/tesseract")
        self.languages = languages
        self.psm = psm
    }

    public static func locateBinary() -> URL? {
        let candidates = ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract", "/usr/bin/tesseract"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return URL(fileURLWithPath: c) }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let p = String(dir) + "/tesseract"
                if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
            }
        }
        return nil
    }

    public var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    public func recognize(image: CGImage, pageIndex: Int, scale: CGFloat, pageHeight: CGFloat) throws -> [TextLine] {
        guard isAvailable else { throw OCRError("tesseract binary not found (brew install tesseract tesseract-lang)") }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bituah-\(UUID().uuidString).png")
        try PageRasterizer.writePNG(image, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let tsv = try run(arguments: [tmp.path, "stdout", "-l", languages, "--psm", String(psm), "tsv"])
        return Self.parseTSV(tsv, pageIndex: pageIndex, scale: scale, imageHeight: CGFloat(image.height))
    }

    func run(arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = binary
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["OMP_THREAD_LIMIT"] = "4"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw OCRError("tesseract exited with \(p.terminationStatus): \(String(data: errData, encoding: .utf8) ?? "")")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// TSV columns: level page_num block_num par_num line_num word_num left top width height conf text
    static func parseTSV(_ tsv: String, pageIndex: Int, scale: CGFloat, imageHeight: CGFloat) -> [TextLine] {
        struct Word { var x: CGFloat; var y: CGFloat; var w: CGFloat; var h: CGFloat; var conf: Double; var text: String }
        var groups: [String: [Word]] = [:]
        var order: [String] = []
        for row in tsv.split(separator: "\n").dropFirst() {
            let cols = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 12, cols[0] == "5" else { continue }
            let text = cols[11].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let conf = Double(cols[10]), conf >= 0 else { continue }
            let key = cols[2] + "/" + cols[3] + "/" + cols[4]
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(Word(x: CGFloat(Double(cols[6]) ?? 0), y: CGFloat(Double(cols[7]) ?? 0),
                                                 w: CGFloat(Double(cols[8]) ?? 0), h: CGFloat(Double(cols[9]) ?? 0),
                                                 conf: conf, text: text))
        }
        var lines: [TextLine] = []
        for key in order {
            let words = groups[key]!
            // Tesseract already emits RTL lines in logical order; keep its order.
            let text = words.map(\.text).joined(separator: " ")
            let minX = words.map(\.x).min()!, maxX = words.map { $0.x + $0.w }.max()!
            let minY = words.map(\.y).min()!, maxY = words.map { $0.y + $0.h }.max()!
            // pixel (top-left origin) → PDF points (bottom-left origin)
            let box = CGRect(x: minX / scale, y: (imageHeight - maxY) / scale,
                             width: (maxX - minX) / scale, height: (maxY - minY) / scale)
            let conf = words.map(\.conf).reduce(0, +) / Double(words.count) / 100.0
            let textWords = words.map { w in
                TextWord(text: w.text,
                         bbox: CGRect(x: w.x / scale, y: (imageHeight - w.y - w.h) / scale, width: w.w / scale, height: w.h / scale),
                         confidence: w.conf / 100.0)
            }
            lines.append(TextLine(text: text, page: pageIndex, bbox: box, confidence: conf, words: textWords))
        }
        // Reading order: top of page first (Tesseract's block order can interleave columns).
        return lines.sorted { a, b in
            if abs(a.bbox.midY - b.bbox.midY) > max(a.bbox.height, b.bbox.height) * 0.6 { return a.bbox.midY > b.bbox.midY }
            return a.bbox.maxX > b.bbox.maxX   // same row: right-to-left
        }
    }
}
#endif

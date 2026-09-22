import Foundation
import PDFKit

/// Tier 1: read the native text layer through PDFKit. Zero ML, ~milliseconds per page,
/// identical API on iOS and macOS. Returns nil lines for pages that are pure images.
public struct PDFTextLayerExtractor {
    public init() {}

    /// Minimum number of Hebrew/Latin letters for a page to count as "has a usable text layer".
    public static let minLettersPerPage = 40

    public func extract(document: PDFDocument) -> [PageText] {
        var pages: [PageText] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let raw = (page.string ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            var lines: [TextLine] = []
            var cursor = 0
            let ns = raw as NSString
            for piece in raw.components(separatedBy: "\n") {
                let len = (piece as NSString).length
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    var box = CGRect.null
                    if cursor + len <= ns.length, let sel = page.selection(for: NSRange(location: cursor, length: len)) {
                        box = sel.bounds(for: page)
                    }
                    lines.append(TextLine(text: piece, page: i, bbox: box, confidence: 1.0))
                }
                cursor += len + 1
            }
            pages.append(PageText(index: i, lines: lines, rawText: raw))
        }
        return pages
    }

    /// Heuristic: does this page carry enough real text to skip OCR?
    public static func hasUsableText(_ page: PageText) -> Bool {
        let letters = page.rawText.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return letters >= minLettersPerPage
    }
}

import Foundation
import CoreGraphics
import UIKit
import BituahCore
import SwiftyTesseract
import libtesseract

/// Tesseract 5 linked into the app (SwiftyTesseract + prebuilt libtesseract xcframework), models from
/// the bundled `tessdata/` folder. Same `OCREngine` protocol as the macOS CLI engine, so the pipeline —
/// Vision digit fusion, normalizer, extractor — is untouched.
final class TesseractiOSEngine: OCREngine {
    static let shared = TesseractiOSEngine()

    let name = "tesseract-ios"
    private let tesseract: Tesseract

    private init() {
        tesseract = Tesseract(languages: [.hebrew, .english], dataSource: Bundle.main, engineMode: .lstmOnly)
        tesseract.perform { api in
            TessBaseAPISetPageSegMode(api, PSM_SINGLE_COLUMN)   // psm 4, best for label/value forms
        }
    }

    func recognize(image: CGImage, pageIndex: Int, scale: CGFloat, pageHeight: CGFloat) throws -> [TextLine] {
        guard let data = UIImage(cgImage: image).pngData() else { throw OCRError("cannot encode page") }
        let imageHeight = CGFloat(image.height)
        let result = tesseract.recognizedBlocks(from: data, for: [.textline, .word])
        switch result {
        case .failure(let e): throw OCRError("tesseract: \(e)")
        case .success(let (_, dict)):
            let lineBlocks = dict[.textline] ?? []
            let wordBlocks = dict[.word] ?? []
            func toPoints(_ b: CGRect) -> CGRect {   // image pixels, top-left origin → PDF points, bottom-left
                CGRect(x: b.minX / scale, y: (imageHeight - b.maxY) / scale, width: b.width / scale, height: b.height / scale)
            }
            var lines: [TextLine] = []
            for lb in lineBlocks {
                let box = lb.boundingBox.cgRect
                let text = lb.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let words = wordBlocks.filter { w in
                    let r = w.boundingBox.cgRect
                    let ov = min(r.maxY, box.maxY) - max(r.minY, box.minY)
                    return ov > 0.5 * min(r.height, box.height) && r.minX >= box.minX - 2 && r.maxX <= box.maxX + 2
                }.map { w in
                    TextWord(text: w.text.trimmingCharacters(in: .whitespacesAndNewlines), bbox: toPoints(w.boundingBox.cgRect), confidence: Double(w.confidence) / 100)
                }.filter { !$0.text.isEmpty }
                // The iterator's line string can glue words together; rebuild from word boxes (reading order).
                let lineText = words.isEmpty ? text : words.map(\.text).joined(separator: " ")
                lines.append(TextLine(text: lineText, page: pageIndex, bbox: toPoints(box), confidence: Double(lb.confidence) / 100, words: words))
            }
            return lines.sorted { a, b in
                if abs(a.bbox.midY - b.bbox.midY) > max(a.bbox.height, b.bbox.height) * 0.6 { return a.bbox.midY > b.bbox.midY }
                return a.bbox.maxX > b.bbox.maxX
            }
        }
    }
}

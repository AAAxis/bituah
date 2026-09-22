import Foundation
import CoreGraphics
import Vision

/// Apple Vision text recognition. **Hebrew is not a supported recognition language** (checked on
/// macOS 27 / iOS 27: `supportedRecognitionLanguages()` lists Arabic but not `he`), so on its own it
/// cannot read the labels. It is still valuable as an on-device, zero-dependency reader of the
/// *numeric* fields (ID, policy number, dates, amounts) and Latin letterheads, and the pipeline
/// uses it to cross-check digits that Tesseract read with low confidence.
public struct VisionOCREngine: OCREngine {
    public let name = "vision"
    public var recognitionLanguages: [String]

    public init(recognitionLanguages: [String] = ["en-US"]) {
        self.recognitionLanguages = recognitionLanguages
    }

    public static var supportsHebrew: Bool {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .accurate
        let langs = (try? r.supportedRecognitionLanguages()) ?? []
        return langs.contains { $0.lowercased().hasPrefix("he") }
    }

    public func recognize(image: CGImage, pageIndex: Int, scale: CGFloat, pageHeight: CGFloat) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false        // do not "correct" digit strings into words
        request.recognitionLanguages = recognitionLanguages
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var lines: [TextLine] = []
        for obs in request.results ?? [] {
            guard let top = obs.topCandidates(1).first else { continue }
            func toPoints(_ b: CGRect) -> CGRect {   // normalized, origin bottom-left → PDF points
                CGRect(x: b.minX * w / scale, y: b.minY * h / scale, width: b.width * w / scale, height: b.height * h / scale)
            }
            let box = toPoints(obs.boundingBox)
            var words: [TextWord] = []
            let str = top.string
            var idx = str.startIndex
            for token in str.split(separator: " ") {
                guard let r = str.range(of: token, range: idx..<str.endIndex) else { continue }
                idx = r.upperBound
                let wb = (try? top.boundingBox(for: r))?.boundingBox ?? obs.boundingBox
                words.append(TextWord(text: String(token), bbox: toPoints(wb), confidence: Double(top.confidence)))
            }
            lines.append(TextLine(text: str, page: pageIndex, bbox: box, confidence: Double(top.confidence), words: words))
        }
        return lines.sorted { $0.bbox.midY > $1.bbox.midY }
    }
}

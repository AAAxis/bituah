import Foundation
import CoreGraphics

/// A word with its box, kept for OCR engines so lines can be fused geometrically.
public struct TextWord: Equatable, Sendable {
    public var text: String
    public var bbox: CGRect
    public var confidence: Double
    public init(text: String, bbox: CGRect, confidence: Double = 1.0) {
        self.text = text; self.bbox = bbox; self.confidence = confidence
    }
}

/// One physical line of text on a page, in logical (reading) order after normalization.
public struct TextLine: Equatable, Sendable {
    public var text: String
    public var page: Int
    /// Bounding box in PDF points, origin bottom-left (PDFKit convention). `.null` when unknown.
    public var bbox: CGRect
    /// Mean OCR confidence 0...1 (1.0 for the native text layer).
    public var confidence: Double
    /// True if the normalizer had to reverse this line to restore logical Hebrew order.
    public var wasReversed: Bool
    /// Word boxes (OCR sources only; empty for the native text layer).
    public var words: [TextWord]

    public init(text: String, page: Int, bbox: CGRect = .null, confidence: Double = 1.0, wasReversed: Bool = false, words: [TextWord] = []) {
        self.text = text
        self.page = page
        self.bbox = bbox
        self.confidence = confidence
        self.wasReversed = wasReversed
        self.words = words
    }
}

/// A page's worth of lines plus a raw dump for CER/WER measurement.
public struct PageText: Sendable {
    public var index: Int
    public var lines: [TextLine]
    public var rawText: String

    public init(index: Int, lines: [TextLine], rawText: String) {
        self.index = index
        self.lines = lines
        self.rawText = rawText
    }
}

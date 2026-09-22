import Foundation
import CoreGraphics

/// Tier 2 abstraction. The pipeline only needs "bitmap in, lines with boxes and confidence out",
/// so the engine can be swapped: Tesseract (CLI here, libtesseract xcframework on iOS),
/// Apple Vision (no Hebrew as of iOS/macOS 26 — Latin/digits only), or a future CoreML model.
public protocol OCREngine {
    var name: String { get }
    /// - Parameters:
    ///   - image: rendered page bitmap
    ///   - pageIndex: 0-based page number
    ///   - scale: pixels per PDF point, used to map boxes back to PDF coordinates
    ///   - pageHeight: page height in points (to flip the y axis)
    func recognize(image: CGImage, pageIndex: Int, scale: CGFloat, pageHeight: CGFloat) throws -> [TextLine]
}

public struct OCRError: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

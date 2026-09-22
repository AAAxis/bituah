import Foundation
import PDFKit
import CoreGraphics
import CoreImage
import CoreText

/// Builds harder variants of the digital test PDFs so the OCR tier and the bidi repair can be measured:
///  * `scan`  — rasterize, rotate slightly, blur, add noise, wrap as an image-only PDF (no text layer).
///  * `visual` — re-typeset the page with every Hebrew line stored in *visual* (reversed) order in
///    the text layer while still rendering correctly. This reproduces the classic broken Israeli PDF
///    where copy-paste yields `הסילופ רפסמ`.
public enum TestSetGenerator {

    public struct ScanOptions {
        public var dpi: CGFloat = 200
        public var rotationDegrees: CGFloat = 0.6
        public var blurRadius: Double = 0.7
        public var noiseAmount: Double = 0.06
        public init() {}
    }

    public static func makeScan(from source: URL, to dest: URL, options: ScanOptions = ScanOptions()) throws {
        guard let doc = PDFDocument(url: source) else { throw OCRError("cannot open \(source.path)") }
        guard let consumer = CGDataConsumer(url: dest as CFURL) else { throw OCRError("cannot write \(dest.path)") }
        var mediaBox = doc.page(at: 0)!.bounds(for: .mediaBox)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw OCRError("cannot create PDF context") }
        let ci = CIContext(options: [.useSoftwareRenderer: false])

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let raster = PageRasterizer.render(page: page, dpi: options.dpi) else { continue }
            var image = CIImage(cgImage: raster.image)
            let extent = image.extent

            // Slight skew, as from a phone camera or a feeder scanner.
            let angle = options.rotationDegrees * .pi / 180
            let t = CGAffineTransform(translationX: extent.midX, y: extent.midY)
                .rotated(by: angle)
                .translatedBy(x: -extent.midX, y: -extent.midY)
            image = image.transformed(by: t)
            // White background behind the rotated page.
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
            image = image.composited(over: white).cropped(to: extent)

            // Optical softness.
            if options.blurRadius > 0, let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(image, forKey: kCIInputImageKey)
                blur.setValue(options.blurRadius, forKey: kCIInputRadiusKey)
                image = (blur.outputImage ?? image).cropped(to: extent)
            }

            // Sensor noise.
            if options.noiseAmount > 0, let gen = CIFilter(name: "CIRandomGenerator"), let noise = gen.outputImage,
               let matrix = CIFilter(name: "CIColorMatrix") {
                let a = CGFloat(options.noiseAmount)
                matrix.setValue(noise.cropped(to: extent), forKey: kCIInputImageKey)
                matrix.setValue(CIVector(x: a, y: 0, z: 0, w: 0), forKey: "inputRVector")
                matrix.setValue(CIVector(x: a, y: 0, z: 0, w: 0), forKey: "inputGVector")
                matrix.setValue(CIVector(x: a, y: 0, z: 0, w: 0), forKey: "inputBVector")
                matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
                matrix.setValue(CIVector(x: -a / 2, y: -a / 2, z: -a / 2, w: 0), forKey: "inputBiasVector")
                if let n = matrix.outputImage, let add = CIFilter(name: "CIAdditionCompositing") {
                    add.setValue(n, forKey: kCIInputImageKey)
                    add.setValue(image, forKey: kCIInputBackgroundImageKey)
                    image = (add.outputImage ?? image).cropped(to: extent)
                }
            }

            // Grayscale, as most scanners deliver.
            if let mono = CIFilter(name: "CIPhotoEffectMono") {
                mono.setValue(image, forKey: kCIInputImageKey)
                image = (mono.outputImage ?? image).cropped(to: extent)
            }

            guard let cg = ci.createCGImage(image, from: extent) else { continue }
            var box = page.bounds(for: .mediaBox)
            pdf.beginPage(mediaBox: &box)
            pdf.draw(cg, in: box)
            pdf.endPage()
        }
        pdf.closePDF()
    }

    /// Typesets a plain-text policy (one line per row, logical order) into a right-aligned A4 PDF with a
    /// proper text layer — used to build held-out templates with different wording and layout.
    public static func makeDocument(fromText text: String, to dest: URL, fontSize: CGFloat = 11) throws {
        guard let consumer = CGDataConsumer(url: dest as CFURL) else { throw OCRError("cannot write \(dest.path)") }
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw OCRError("cannot create PDF context") }
        let font = CTFontCreateWithName("Arial Hebrew" as CFString, fontSize, nil)
        let bold = CTFontCreateWithName("Arial Hebrew Bold" as CFString, fontSize + 3, nil)
        pdf.beginPage(mediaBox: &mediaBox)
        pdf.textMatrix = .identity
        var y = mediaBox.maxY - 60
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { y -= 8; continue }
            let attr = NSAttributedString(string: line, attributes: [.font: i == 0 ? bold : font])
            let ctLine = CTLineCreateWithAttributedString(attr)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            pdf.textPosition = CGPoint(x: mediaBox.maxX - 50 - CGFloat(width), y: y)
            CTLineDraw(ctLine, pdf)
            y -= (i == 0 ? 26 : 18)
        }
        pdf.endPage()
        pdf.closePDF()
    }

    /// Re-typesets the text of `source` into a new PDF whose text layer stores each line fully reversed
    /// (LTR-forced): the page still reads correctly, but the text layer is in visual order.
    /// PDFKit's extractor applies its own bidi pass, so what the parser sees is logical Hebrew with
    /// **mirrored digits** (`810294830`, `6202/10/10`, `05.542`) — the classic "digit inversion" defect.
    public static func makeVisualOrderVariant(from source: URL, to dest: URL) throws {
        guard let doc = PDFDocument(url: source) else { throw OCRError("cannot open \(source.path)") }
        guard let consumer = CGDataConsumer(url: dest as CFURL) else { throw OCRError("cannot write \(dest.path)") }
        var mediaBox = doc.page(at: 0)!.bounds(for: .mediaBox)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw OCRError("cannot create PDF context") }
        let font = CTFontCreateWithName("Arial Hebrew" as CFString, 11, nil)

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var box = page.bounds(for: .mediaBox)
            pdf.beginPage(mediaBox: &box)
            pdf.textMatrix = .identity
            var y = box.maxY - 40
            for raw in (page.string ?? "").components(separatedBy: .newlines) {
                let line = HebrewNormalizer.cleanCharacters(raw)
                guard !line.isEmpty else { continue }
                // Store visual order: reverse everything, including digit runs.
                let visual = String(line.reversed())
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    kCTWritingDirectionAttributeName as NSAttributedString.Key:
                        [NSNumber(value: Int(CTWritingDirection.leftToRight.rawValue) | kCTWritingDirectionOverride)],
                ]
                let attr = NSAttributedString(string: visual, attributes: attrs)
                let ctLine = CTLineCreateWithAttributedString(attr)
                let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                pdf.textPosition = CGPoint(x: box.maxX - 40 - CGFloat(width), y: y)   // right-aligned
                CTLineDraw(ctLine, pdf)
                y -= 16
                if y < 40 { break }
            }
            pdf.endPage()
        }
        pdf.closePDF()
    }
}

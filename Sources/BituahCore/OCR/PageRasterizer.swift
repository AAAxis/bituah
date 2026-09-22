import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Renders a PDF page into a bitmap for OCR. Pure CoreGraphics, so it behaves identically on iOS.
public enum PageRasterizer {

    public struct Raster {
        public var image: CGImage
        /// pixels per PDF point (dpi / 72)
        public var scale: CGFloat
        public var pageBounds: CGRect
    }

    public static func render(page: PDFPage, dpi: CGFloat = 300) -> Raster? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72.0
        let w = Int((bounds.width * scale).rounded()), h = Int((bounds.height * scale).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(true)
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        guard let img = ctx.makeImage() else { return nil }
        return Raster(image: img, scale: scale, pageBounds: bounds)
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "bituah", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create PNG at \(url.path)"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "bituah", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG write failed"])
        }
    }
}

// swift-tools-version:5.3
// Vendored: prebuilt Tesseract 5 + Leptonica xcframework from SwiftyTesseract/libtesseract 0.2.0
// (sha256 cc42f3424047adc7064e6bb67d5039385629ee42199fcbb0553f57f1110d8c90). Kept local so the
// iOS app builds offline.
import PackageDescription

let package = Package(
  name: "libtesseract",
  products: [.library(name: "libtesseract", targets: ["libtesseract"])],
  targets: [.binaryTarget(name: "libtesseract", path: "libtesseract.xcframework")]
)

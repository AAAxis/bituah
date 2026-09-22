// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "bituah",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
    ],
    products: [
        // Reusable engine: drop this target into an iOS app as-is.
        .library(name: "BituahCore", targets: ["BituahCore"]),
        // Command-line driver used for the take-home evaluation.
        .executable(name: "bituah", targets: ["bituah"]),
        .executable(name: "BituahDemo", targets: ["BituahDemo"]),
    ],
    targets: [
        .target(
            name: "BituahCore",
            path: "Sources/BituahCore",
            linkerSettings: [
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
            ]
        ),
        .executableTarget(
            name: "bituah",
            dependencies: ["BituahCore"],
            path: "Sources/bituah"
        ),
        // SwiftUI front-end (RTL form with confidence + evidence per field). macOS here, iOS-ready views.
        .executableTarget(
            name: "BituahDemo",
            dependencies: ["BituahCore"],
            path: "Sources/BituahDemo"
        ),
        .testTarget(
            name: "BituahCoreTests",
            dependencies: ["BituahCore"],
            path: "Tests/BituahCoreTests"
        ),
    ]
)

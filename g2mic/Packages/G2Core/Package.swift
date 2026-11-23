// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "G2Core",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "G2Core", targets: ["G2Core"]),
    ],
    targets: [
        // Google's liblc3 (Apache-2.0), vendored unmodified. Decodes the G2 mic stream.
        .target(
            name: "CLC3",
            path: "Sources/CLC3",
            exclude: ["LICENSE", "README.md"],
            publicHeadersPath: "include"
        ),
        // Platform-independent G2 protocol + audio code (no CoreBluetooth, so it builds and tests anywhere).
        .target(name: "G2Core", dependencies: ["CLC3"]),
        .testTarget(name: "G2CoreTests", dependencies: ["G2Core", "CLC3"]),
    ]
)

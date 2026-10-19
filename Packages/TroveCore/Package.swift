// swift-tools-version: 6.0
// TroveCore: everything that isn't UI or Apple-only frameworks: the data model, sync journals,
// merge rules, encryption, importers, Tier-0 extraction and search. Builds and tests on Linux too.
import PackageDescription

let package = Package(
    name: "TroveCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TroveCore", targets: ["TroveCore"]),
    ],
    dependencies: [
        // On Apple platforms this re-exports CryptoKit; on Linux it provides the same API.
        .package(url: "https://github.com/apple/swift-crypto.git", "4.0.0"..<"6.0.0"),
    ],
    targets: [
        .target(
            name: "TroveCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(
            name: "TroveCoreTests",
            dependencies: ["TroveCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

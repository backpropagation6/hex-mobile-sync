// swift-tools-version: 6.2
//
// HexMobileWhisper: how Hex Mobile asks WhisperKit for a text. The decoding
// options, the cut of a long recording into pieces and the assembly of their
// text live here, in one place, so that the app (WhisperModelHolder) and
// `tools/whisper-bench` (a Mac command line tool) run the very same recipe.
// Only the compute units differ (the phone's Neural Engine, the Mac's).
//
// WhisperKit is pinned to the exact tag the app uses (commit 1bbc57cb); the
// repository was `argmaxinc/WhisperKit` and redirects to this one. HexMobileCore
// stays free of it (the keyboard and widget extensions link that package).

import PackageDescription

let package = Package(
    name: "HexMobileWhisper",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "HexMobileWhisper", targets: ["HexMobileWhisper"]),
    ],
    dependencies: [
        .package(path: "../HexMobileCore"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.1"),
    ],
    targets: [
        .target(
            name: "HexMobileWhisper",
            dependencies: [
                .product(name: "HexMobileCore", package: "HexMobileCore"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .testTarget(
            name: "HexMobileWhisperTests",
            dependencies: ["HexMobileWhisper"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

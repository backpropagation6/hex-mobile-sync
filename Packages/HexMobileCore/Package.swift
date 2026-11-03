// swift-tools-version: 6.2
//
// HexMobileCore: models, text processing, sync codec, history and IPC
// constants shared by the Hex Mobile Sync iOS app and its extensions.
// Pure Foundation code, testable on macOS with `swift test`.
//
// HexMobileSpeech: the pieces that talk to Apple's Speech and Foundation
// Models frameworks (recognition of an audio file, text cleanup). They live
// here, not in the app, so the `tools/asr-bench` command line tool runs the
// very same code on a Mac. Not unit tested (the models are not deterministic);
// everything that can be decided without a model is in HexMobileCore.

import PackageDescription

let package = Package(
    name: "HexMobileCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "HexMobileCore", targets: ["HexMobileCore"]),
        .library(name: "HexMobileSpeech", targets: ["HexMobileSpeech"]),
    ],
    targets: [
        .target(name: "HexMobileCore"),
        .target(name: "HexMobileSpeech", dependencies: ["HexMobileCore"]),
        .testTarget(
            name: "HexMobileSpeechTests",
            dependencies: ["HexMobileSpeech"]
        ),
        .testTarget(
            name: "HexMobileCoreTests",
            dependencies: ["HexMobileCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)

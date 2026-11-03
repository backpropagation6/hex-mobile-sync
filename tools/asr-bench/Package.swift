// swift-tools-version: 6.2
//
// asr-bench: compares the recognizer variants of Hex Mobile on the same audio
// clips, on a Mac. It uses the very same code as the app (HexMobileSpeech), so
// a number here is a number about the app's pipeline.
//
//   swift run -c release --package-path tools/asr-bench asr-bench run <clips-dir> ...
//
// See README.md.

import PackageDescription

let package = Package(
    name: "asr-bench",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Packages/HexMobileCore"),
    ],
    targets: [
        .executableTarget(
            name: "asr-bench",
            dependencies: [
                .product(name: "HexMobileCore", package: "HexMobileCore"),
                .product(name: "HexMobileSpeech", package: "HexMobileCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

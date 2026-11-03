// swift-tools-version: 6.2
//
// whisper-bench: reads one audio clip with Whisper on a Mac, through the very
// same recipe as the app (HexMobileWhisper: the decoding options, the cut of a
// long recording into pieces). It prints the text, so `asr-bench` can score it
// as `--external whisper=<this executable>`. Only the compute units differ from
// the phone: the Mac's Neural Engine, not the iPhone's.
//
//   swift build -c release --package-path tools/whisper-bench
//
// See README.md.

import PackageDescription

let package = Package(
    name: "whisper-bench",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Packages/HexMobileCore"),
        .package(path: "../../Packages/HexMobileWhisper"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "whisper-bench",
            dependencies: [
                .product(name: "HexMobileCore", package: "HexMobileCore"),
                .product(name: "HexMobileWhisper", package: "HexMobileWhisper"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

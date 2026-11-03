import Foundation

/// A recognizer outside Apple's frameworks (Whisper, a cloud API…), compared
/// on the same clips. It is a function from an audio file to its text.
typealias ExternalTranscribe = @Sendable (URL) async throws -> String

enum ExternalVariants {
    /// Variants compiled in. To add one in code, append `("whisper", { url in … })`.
    /// Nothing is registered: no Whisper dependency or model is part of the
    /// app or of this tool.
    static let registered: [(name: String, transcribe: ExternalTranscribe)] = []

    /// A variant that runs a program: `--external whisper=/abs/path/to/script`.
    /// The program gets the clip path as its only argument and prints the text
    /// on stdout; a nonzero exit is an error for that clip.
    static func command(name: String, executable: String, timeout: Duration = .seconds(180)) -> (name: String, transcribe: ExternalTranscribe) {
        (name, { url in
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let process = Process()
                    process.executableURL = URL(filePath: executable)
                    process.arguments = [url.path]
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    // Reads until the program closes stdout, then waits for it.
                    let data = try output.fileHandleForReading.readToEnd() ?? Data()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        throw BenchError("\(name): exit \(process.terminationStatus)")
                    }
                    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw BenchError("\(name): timeout")
                }
                defer { group.cancelAll() }
                return try await group.next() ?? ""
            }
        })
    }
}

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

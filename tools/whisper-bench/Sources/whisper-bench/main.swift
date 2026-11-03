import Foundation
import HexMobileCore
import HexMobileWhisper
import WhisperKit

// whisper-bench <clip> [--terms FILE] [--no-pieces] [--models DIR] [--language it] [--cpu]
//
// The text goes to stdout (one line); everything else to stderr. The terms
// (one per line, like asr-bench --vocabulary) come from --terms or from the
// HEX_WHISPER_TERMS environment variable: asr-bench's --external passes only
// the clip path. Exit code 1 on any failure, with the reason on stderr.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("whisper-bench: \(message)\n".utf8))
    exit(1)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

var clip: String?
var termsFile = ProcessInfo.processInfo.environment["HEX_WHISPER_TERMS"]
var modelsRoot = ProcessInfo.processInfo.environment["HEX_WHISPER_MODELS"]
    ?? FileManager.default.currentDirectoryPath + "/build/whisper-models"
var language: String? = "it"
var splitIntoPieces = true
var cpuOnly = false

func value(for option: String, in arguments: inout ArraySlice<String>) -> String {
    guard let next = arguments.popFirst() else { fail("\(option) needs a value") }
    return next
}

var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--terms": termsFile = value(for: argument, in: &arguments)
    case "--models": modelsRoot = value(for: argument, in: &arguments)
    case "--language": language = value(for: argument, in: &arguments)
    case "--no-pieces": splitIntoPieces = false
    case "--cpu": cpuOnly = true
    case "-h", "--help":
        note("usage: whisper-bench <clip> [--terms FILE] [--no-pieces] [--models DIR] [--language it] [--cpu]")
        exit(0)
    default:
        if argument.hasPrefix("--") { fail("unknown option \(argument)") }
        clip = argument
    }
}
guard let clip else { fail("no clip given") }

// The layout `make push-whisper-model` and the README describe.
let modelName = "openai_whisper-large-v3-v20240930_turbo_632MB"
let modelFolder = modelsRoot + "/models/argmaxinc/whisperkit-coreml/" + modelName
let tokenizerFolder = modelsRoot + "/tokenizers/models/openai/whisper-large-v3"
for required in WhisperLocator.requiredModels where !FileManager.default.fileExists(atPath: modelFolder + "/" + required) {
    fail("missing \(modelFolder)/\(required) (see README, Whisper on the iPhone)")
}
for required in WhisperLocator.requiredTokenizerFiles where !FileManager.default.fileExists(atPath: tokenizerFolder + "/" + required) {
    fail("missing \(tokenizerFolder)/\(required)")
}

var terms: [String] = []
if let termsFile {
    guard let text = try? String(contentsOfFile: termsFile, encoding: .utf8) else { fail("cannot read \(termsFile)") }
    terms = text.split(whereSeparator: \.isNewline).map { String($0) }
}

let compute = ModelComputeOptions(
    melCompute: .cpuOnly,
    audioEncoderCompute: cpuOnly ? .cpuOnly : .cpuAndNeuralEngine,
    textDecoderCompute: cpuOnly ? .cpuOnly : .cpuAndNeuralEngine
)
let loadStarted = Date()
let kit: WhisperKit
do {
    kit = try await WhisperKit(WhisperKitConfig(
        modelFolder: modelFolder,
        tokenizerFolder: URL(fileURLWithPath: tokenizerFolder),
        computeOptions: compute,
        verbose: false,
        logLevel: .none,
        prewarm: false,
        load: true,
        download: false
    ))
} catch {
    fail("load failed: \(error)")
}
note(String(format: "whisper load dt=%.2f", Date().timeIntervalSince(loadStarted)))

do {
    let samples = try WhisperRecipe.loadSamples(path: clip)
    let started = Date()
    let output = try await WhisperRecipe.transcribe(
        kit: kit,
        samples: samples,
        language: language,
        terms: terms,
        splitIntoPieces: splitIntoPieces,
        onPlan: { plan in
            note(plan.prompt.logLine)
            note(plan.logLine)
            let cuts = plan.pieces.map { String(format: "%.1f", Double($0.lowerBound) / Double(WhisperClips.sampleRate)) }
            note("whisper cuts at=\(cuts.joined(separator: ","))")
        }
    )
    note(output.timings.logLine)
    if let joined = output.joined { note(joined.logLine) }
    note(String(format: "whisper run dt=%.2f rec=%.1fs", Date().timeIntervalSince(started), output.plan.recordingSeconds))
    print(output.text.replacingOccurrences(of: "\n", with: " "))
} catch {
    fail("transcription failed: \(error)")
}

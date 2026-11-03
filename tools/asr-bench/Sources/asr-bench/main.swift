import Foundation
import HexMobileCore
import HexMobileSpeech

let usage = """
asr-bench: compares recognizer variants on the same audio clips (Mac).

  asr-bench install [--locale it-IT]
      Downloads Apple's speech models for the locale (SpeechTranscriber and
      DictationTranscriber). Needs a network; the first run only.

  asr-bench run <clips-dir> [options]
      Runs every variant on every clip (.caf .wav .m4a .aiff .mp3) in the folder.
      --reference FILE      the right text per clip: JSON {"id": "text"} or
                            lines "id<TAB>text"; gives the WER per variant
      --variants a,b,c      fast accurate dictation live dual app clean (default: all
                            but dual);
                            external:<name> for each --external
      --locale it-IT        recognition locale
      --vocabulary FILE     one term per line: contextual strings and spelling
      --realtime            feed the live variants at the speed of speech, so the
                            latencies are real (the clip takes as long as it lasts)
      --cleanup-timeout S   seconds the `clean` variant lets the cleanup take (default 3;
                            `app` uses the app's own limit, which grows with the text)
      --no-warmup           do not load the models on the first clip first
      --external NAME=EXE   another recognizer: EXE <clip> prints the text
      --json FILE           also write the results as JSON

Variants: fast = SpeechTranscriber with fastResults (the live transcript),
accurate = without fastResults (the final pass), dictation = DictationTranscriber
with punctuation, live = streaming simulation of the live transcript, dual = the
fast and the accurate recognizer in one analyzer (not what the app does; it is
here to measure that idea), app = the
app's pipeline after the stop (live, final pass, cleanup, vocabulary), clean =
the accurate text through the cleanup. Clips with a <id>.json written by the app
also show the phone's own texts (phone-live, phone-final, phone-whisper,
phone-clean, phone-inserted).
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("asr-bench: \(message)\n".utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { print(usage); exit(0) }
arguments.removeFirst()

func takeValue(_ flag: String, _ arguments: inout [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    guard index + 1 < arguments.count else { fail("\(flag) needs a value") }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func takeFlag(_ flag: String, _ arguments: inout [String]) -> Bool {
    guard let index = arguments.firstIndex(of: flag) else { return false }
    arguments.remove(at: index)
    return true
}

switch command {
case "install":
    let locale = Locale(identifier: takeValue("--locale", &arguments) ?? "it-IT")
    for variant in [RecognitionVariant.speechAccurate, .dictation] {
        do {
            nonisolated(unsafe) var last = -1
            try await ClipTranscriber.install(variant: variant, locale: locale) { fraction in
                let step = Int(fraction * 10)
                if step != last { last = step; print("\(variant.rawValue) \(Int(fraction * 100))%") }
            }
            print("\(variant.rawValue): installed for \(locale.identifier(.bcp47))")
        } catch {
            fail("\(variant.rawValue): \(error)")
        }
    }

case "run":
    let localeID = takeValue("--locale", &arguments)
    let referencePath = takeValue("--reference", &arguments)
    let variantList = takeValue("--variants", &arguments)
    let vocabularyPath = takeValue("--vocabulary", &arguments)
    let timeout = takeValue("--cleanup-timeout", &arguments)
    let jsonPath = takeValue("--json", &arguments)
    var externalSpecs: [String] = []
    while let spec = takeValue("--external", &arguments) { externalSpecs.append(spec) }
    let realtime = takeFlag("--realtime", &arguments)
    let noWarmup = takeFlag("--no-warmup", &arguments)
    guard let folder = arguments.first, !folder.hasPrefix("--") else { fail("run needs the clips folder\n\n\(usage)") }
    guard arguments.count == 1 else { fail("unexpected arguments: \(arguments.dropFirst().joined(separator: " "))") }

    var options = BenchOptions(folder: URL(filePath: folder, directoryHint: .isDirectory))
    if let localeID { options.locale = Locale(identifier: localeID) }
    if let referencePath { options.reference = URL(filePath: referencePath) }
    if let variantList { options.variants = variantList.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
    if let timeout, let seconds = Double(timeout) { options.cleanupTimeout = .milliseconds(Int(seconds * 1000)) }
    if let vocabularyPath {
        guard let text = try? String(contentsOfFile: vocabularyPath, encoding: .utf8) else { fail("cannot read \(vocabularyPath)") }
        options.vocabulary = TermIdentity.uniquePhrases(text.split(whereSeparator: \.isNewline).map(String.init))
    }
    options.realtime = realtime
    options.warmup = !noWarmup
    for spec in externalSpecs {
        guard let equals = spec.firstIndex(of: "="), equals != spec.startIndex else { fail("--external wants NAME=/absolute/path") }
        let name = String(spec[..<equals])
        let path = String(spec[spec.index(after: equals)...])
        guard path.hasPrefix("/") else { fail("--external: the program path must be absolute") }
        options.externals.append(ExternalVariants.command(name: name, executable: path))
    }
    for external in options.externals where !options.variants.contains("external:\(external.name)") {
        options.variants.append("external:\(external.name)")
    }
    do {
        let reports = try await Bench.run(options)
        Report.printSummary(reports)
        if let jsonPath { try Report.writeJSON(reports, to: URL(filePath: jsonPath)) }
    } catch {
        fail("\(error)")
    }

default:
    print(usage)
    exit(command == "help" || command == "--help" ? 0 : 2)
}

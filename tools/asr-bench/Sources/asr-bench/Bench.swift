import AVFAudio
import Foundation
import HexMobileCore
import HexMobileSpeech

struct BenchOptions: Sendable {
    var folder: URL
    var locale = Locale(identifier: "it-IT")
    var variants = ["fast", "accurate", "dictation", "live", "app", "clean"]
    var reference: URL?
    var vocabulary: [String] = []
    var realtime = false
    var warmup = true
    var cleanupTimeout: Duration = .seconds(3)
    var externals: [(name: String, transcribe: ExternalTranscribe)] = ExternalVariants.registered
    var jsonOutput: URL?
}

struct WERNumbers: Codable, Sendable {
    var substitutions: Int
    var deletions: Int
    var insertions: Int
    var words: Int

    var score: WordErrorRate.Score {
        .init(substitutions: substitutions, deletions: deletions, insertions: insertions, referenceWords: words)
    }
}

/// One variant on one clip.
struct Measurement: Codable, Sendable {
    var variant: String
    var text: String?
    /// The latency the variant adds: the recognition time of a file pass, the
    /// stop-to-done time of the live transcript, or stop-to-text for `app`.
    var seconds: Double?
    var note: String?
    var error: String?
    var wer: WERNumbers?
}

struct ClipReport: Codable, Sendable {
    var id: String
    var audioSeconds: Double
    var reference: String?
    var measurements: [Measurement]
}

enum Bench {
    static let audioExtensions: Set<String> = ["caf", "wav", "m4a", "aiff", "mp3"]

    static func run(_ options: BenchOptions) async throws -> [ClipReport] {
        let files = try FileManager.default.contentsOfDirectory(at: options.folder, includingPropertiesForKeys: nil)
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !files.isEmpty else { throw BenchError("no audio clips in \(options.folder.path)") }
        let references = try options.reference.map { try ReferenceFile.parse(Data(contentsOf: $0)) } ?? [:]
        print("cleanup availability=\(TextCleaner.availability(for: options.locale))  clips=\(files.count)  references=\(references.count)  realtime=\(options.realtime)")

        if options.warmup, let first = files.first {
            print("warming up the models on \(first.lastPathComponent) (not counted)...")
            _ = await measure(file: first, id: "warmup", reference: nil, metadata: nil, options: options)
        }
        var reports: [ClipReport] = []
        for file in files {
            let id = file.deletingPathExtension().lastPathComponent
            let metadata = (try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("json")))
                .flatMap { try? ClipMetadata.decode(from: $0) }
            let report = await measure(file: file, id: id, reference: references[id], metadata: metadata, options: options)
            reports.append(report)
            Report.printClip(report)
        }
        return reports
    }

    /// Every requested variant on one clip. A failing variant is recorded as
    /// an error for that clip and never stops the others.
    static func measure(file: URL, id: String, reference: String?, metadata: ClipMetadata?, options: BenchOptions) async -> ClipReport {
        let audioSeconds = (try? AVAudioFile(forReading: file)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        let locale = options.locale
        let vocabulary = options.vocabulary
        var results: [String: Measurement] = [:]
        var order: [String] = []

        func record(_ measurement: Measurement) {
            var measurement = measurement
            if let reference, let text = measurement.text {
                let score = WordErrorRate.score(reference: reference, hypothesis: text)
                measurement.wer = WERNumbers(
                    substitutions: score.substitutions, deletions: score.deletions,
                    insertions: score.insertions, words: score.referenceWords
                )
            }
            if results[measurement.variant] == nil { order.append(measurement.variant) }
            results[measurement.variant] = measurement
        }

        func filePass(_ variant: RecognitionVariant, name: String) async -> Measurement {
            do {
                let result = try await ClipTranscriber.transcribe(file: file, locale: locale, variant: variant, contextualStrings: vocabulary)
                return Measurement(variant: name, text: result.text.trimmingCharacters(in: .whitespacesAndNewlines), seconds: result.seconds)
            } catch {
                return Measurement(variant: name, error: "\(error)")
            }
        }
        var liveCache: LiveResult?
        func live() async throws -> LiveResult {
            if let liveCache { return liveCache }
            let value = try await LiveStream.run(file: file, locale: locale, contextualStrings: vocabulary, realtime: options.realtime)
            liveCache = value
            return value
        }
        var accurateCache: Measurement?
        func accurate() async -> Measurement {
            if let accurateCache { return accurateCache }
            let value = await filePass(.speechAccurate, name: "accurate")
            accurateCache = value
            return value
        }

        for variant in options.variants {
            switch variant {
            case "fast":
                record(await filePass(.speechFast, name: "fast"))
            case "accurate":
                record(await accurate())
            case "dictation":
                record(await filePass(.dictation, name: "dictation"))
            case "live":
                do {
                    let value = try await live()
                    let first = value.firstResult.map { String(format: "%.2f", $0) } ?? "-"
                    record(Measurement(variant: "live", text: value.text, seconds: value.stopToDone, note: "first result \(first) s, \(value.resultsBeforeStop) results before the stop, stop to done \(String(format: "%.2f", value.stopToDone)) s"))
                } catch {
                    record(Measurement(variant: "live", error: "\(error)"))
                }
            case "dual":
                do {
                    let both = try await LiveStream.stream(file: file, locale: locale, contextualStrings: vocabulary, realtime: options.realtime, kinds: [.fast, .accurate])
                    for kind in [StreamKind.fast, .accurate] {
                        guard let value = both[kind] else { continue }
                        let first = value.firstResult.map { String(format: "%.2f", $0) } ?? "none"
                        record(Measurement(
                            variant: "dual-\(kind.rawValue)", text: value.text, seconds: value.stopToDone,
                            note: "first result \(first) s, \(value.resultsBeforeStop) results before the stop, stop to done \(String(format: "%.2f", value.stopToDone)) s"
                        ))
                    }
                } catch {
                    record(Measurement(variant: "dual-fast", error: "\(error)"))
                }
            case "clean":
                let base = await accurate()
                guard let text = base.text, !text.isEmpty else {
                    record(Measurement(variant: "clean", error: "no accurate text to clean"))
                    break
                }
                let report = await TextCleaner(locale: locale).clean(text, timeout: options.cleanupTimeout)
                let spelled = PersonalVocabulary.respell(report.text, terms: vocabulary).text
                record(Measurement(variant: "clean", text: spelled, seconds: report.seconds, note: "cleanup \(report.outcome.rawValue) reason=\(report.reason)"))
            case "app":
                record(await appPipeline(file: file, audioSeconds: audioSeconds, options: options, live: live))
            case let name where name.hasPrefix("external:"):
                let key = String(name.dropFirst("external:".count))
                guard let external = options.externals.first(where: { $0.name == key }) else { break }
                let started = ContinuousClock.now
                do {
                    let text = try await external.transcribe(file)
                    record(Measurement(variant: name, text: text, seconds: seconds(from: started)))
                } catch {
                    record(Measurement(variant: name, error: "\(error)"))
                }
            default:
                break
            }
        }
        if let metadata {
            record(Measurement(variant: "phone-live", text: metadata.liveText))
            if let text = metadata.finalPassText { record(Measurement(variant: "phone-final", text: text, seconds: metadata.finalPassSeconds)) }
            if let outcome = metadata.whisperOutcome {
                // Whisper's own text beside Apple's, when the phone ran it;
                // otherwise why it did not (`fallback:not-ready`, `fallback:budget`…).
                record(Measurement(variant: "phone-whisper", text: metadata.whisperText, seconds: metadata.whisperSeconds, note: "outcome=\(outcome)"))
            }
            if let text = metadata.cleanedText { record(Measurement(variant: "phone-clean", text: text, seconds: metadata.cleanupSeconds)) }
            record(Measurement(
                variant: "phone-inserted",
                text: metadata.insertedText,
                seconds: metadata.stopToTextSeconds,
                note: metadata.finalEngine.map { "final_engine=\($0)" }
            ))
        }
        return ClipReport(id: id, audioSeconds: audioSeconds, reference: reference, measurements: order.compactMap { results[$0] })
    }

    /// The app's pipeline after the stop, on the Mac: the live text, the
    /// accurate final pass with its timeout and fallbacks, the cleanup with
    /// what is left of the 8 s budget, then the vocabulary spelling.
    private static func appPipeline(
        file: URL,
        audioSeconds: Double,
        options: BenchOptions,
        live: () async throws -> LiveResult
    ) async -> Measurement {
        do {
            let liveResult = try await live()
            var elapsed = liveResult.stopToDone
            let pass = await FinalPass.run(
                engine: AppleFinalPassEngine(),
                fileURL: file,
                locale: options.locale,
                contextualStrings: options.vocabulary,
                live: liveResult.text,
                recordingSeconds: audioSeconds
            )
            elapsed += pass.seconds
            var text = pass.text
            var cleanupNote = "cleanup skipped"
            if !text.isEmpty {
                switch FinalPassPolicy.cleanupPlan(elapsedSinceStop: elapsed, characters: text.count) {
                case let .run(timeout):
                    let report = await TextCleaner(locale: options.locale).clean(text, timeout: .milliseconds(Int(timeout * 1000)))
                    elapsed += report.seconds
                    text = report.text
                    cleanupNote = "cleanup \(report.outcome.rawValue) reason=\(report.reason)"
                case .skip:
                    cleanupNote = "cleanup fallback reason=budget"
                }
            }
            text = PersonalVocabulary.respell(text, terms: options.vocabulary).text
            return Measurement(
                variant: "app", text: text, seconds: elapsed,
                note: "final pass \(pass.outcome.rawValue) reason=\(pass.reason) \(String(format: "%.2f", pass.seconds)) s, \(cleanupNote)"
            )
        } catch {
            return Measurement(variant: "app", error: "\(error)")
        }
    }

    private static func seconds(from instant: ContinuousClock.Instant) -> Double {
        instant.duration(to: .now).asSeconds
    }
}

extension Duration {
    var asSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

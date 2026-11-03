import AVFAudio
import Foundation
import HexMobileCore
import Speech

/// What one recognizer produced while a clip was streamed to it.
struct LiveResult: Sendable {
    var text: String
    /// Seconds from the first audio to the first result.
    var firstResult: Double?
    /// How many results arrived before the end of the audio: the live updates
    /// the user would have seen while talking.
    var resultsBeforeStop: Int
    /// Seconds from the end of the audio to the end of the analysis: what the
    /// user waits for after the stop before the final pass can start.
    var stopToDone: Double
    var audioSeconds: Double
}

/// The two recognizers of the app, as streaming modules.
enum StreamKind: String, Sendable {
    /// `fastResults` and volatile results: the live transcript.
    case fast
    /// Neither: the final pass.
    case accurate
}

/// Feeds a clip to a fast `SpeechTranscriber` the way the app's microphone tap
/// does (100 ms buffers of the analyzer's format, volatile and fast results),
/// and reports the text and the latencies. With `realtime` the buffers arrive
/// at the speed of speech, which is what makes the latencies meaningful; without
/// it the clip goes in as fast as the analyzer takes it.
enum LiveStream {
    /// The fast recognizer alone, as the live transcript uses it.
    static func run(file: URL, locale: Locale, contextualStrings: [String], realtime: Bool) async throws -> LiveResult {
        guard let result = try await stream(file: file, locale: locale, contextualStrings: contextualStrings, realtime: realtime, kinds: [.fast])[.fast] else {
            throw BenchError("no result")
        }
        return result
    }

    /// The same audio to several recognizers in ONE analyzer (the "dual
    /// transcriber" idea: fast live text and accurate final text from a single
    /// pass over the microphone audio). The app does not do this; the variant
    /// is here to say what it costs.
    static func stream(
        file: URL,
        locale: Locale,
        contextualStrings: [String],
        realtime: Bool,
        kinds: [StreamKind]
    ) async throws -> [StreamKind: LiveResult] {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw BenchError("speech recognition does not support \(locale.identifier(.bcp47))")
        }
        let transcribers = kinds.map { kind in
            (kind, SpeechTranscriber(
                locale: supported,
                transcriptionOptions: [],
                reportingOptions: kind == .fast ? [.volatileResults, .fastResults] : [],
                attributeOptions: []
            ))
        }
        let modules: [any SpeechModule] = transcribers.map { $0.1 }
        guard await AssetInventory.status(forModules: modules) == .installed else {
            throw BenchError("the speech model for \(supported.identifier(.bcp47)) is not installed (asr-bench install)")
        }
        let audioFile = try AVAudioFile(forReading: file)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: audioFile.processingFormat) else {
            throw BenchError("no audio format for the analyzer")
        }
        let converter = format == audioFile.processingFormat ? nil : AVAudioConverter(from: audioFile.processingFormat, to: format)
        if format != audioFile.processingFormat, converter == nil {
            throw BenchError("cannot convert \(audioFile.processingFormat) to \(format)")
        }

        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: contextualStrings]
            try await analyzer.setContext(context)
        }
        let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let began = ContinuousClock.now
        // Counted by the feeding loop below, read by the collectors: an
        // unsynchronized count would race, so it lives behind a lock.
        let stopped = StopFlag()
        let collectors = transcribers.map { kind, transcriber in
            (kind, Task { () -> (String, Double?, Int) in
                var assembler = TranscriptAssembler()
                var first: Double?
                var before = 0
                for try await result in transcriber.results {
                    if first == nil { first = seconds(from: began) }
                    if !stopped.isSet { before += 1 }
                    assembler.receive(text: String(result.text.characters), isFinal: result.isFinal)
                }
                return (assembler.text, first, before)
            })
        }
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: inputs)

        let chunk = AVAudioFrameCount(audioFile.processingFormat.sampleRate / 10)
        let fed = ContinuousClock.now
        var sent = 0
        while audioFile.framePosition < audioFile.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: chunk) else { break }
            try audioFile.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0 else { break }
            continuation.yield(AnalyzerInput(buffer: try convert(buffer, with: converter, to: format)))
            sent += 1
            if realtime {
                try await Task.sleep(until: fed.advanced(by: .milliseconds(100 * sent)), clock: .continuous)
            }
        }
        let stopAt = ContinuousClock.now
        stopped.set()
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        var results: [StreamKind: LiveResult] = [:]
        for (kind, collector) in collectors {
            let (text, first, before) = try await collector.value
            results[kind] = LiveResult(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                firstResult: first,
                resultsBeforeStop: before,
                stopToDone: seconds(from: stopAt),
                audioSeconds: Double(audioFile.length) / audioFile.processingFormat.sampleRate
            )
        }
        return results
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw BenchError("cannot allocate a conversion buffer")
        }
        nonisolated(unsafe) var delivered = false
        nonisolated(unsafe) let source = buffer
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, failure == nil else { throw BenchError("conversion failed: \(failure?.localizedDescription ?? "unknown")") }
        return output
    }

    private static func seconds(from instant: ContinuousClock.Instant) -> Double {
        let d = instant.duration(to: .now)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

/// A flag set once, read from other tasks.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

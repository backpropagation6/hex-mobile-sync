import AVFAudio
import Foundation
import HexMobileCore
import HexMobileSpeech
import Speech

/// On-device transcription with Apple `SpeechAnalyzer` (iOS 26+). No audio
/// or text leaves the device.
actor OnDeviceSpeechEngine: TranscriptionEngine {
    nonisolated let identifier = "on-device"

    private struct Run {
        var analyzer: SpeechAnalyzer
        var input: AnalyzerInputPipe
        var updates: AsyncStream<TranscriptUpdate>.Continuation
        var resultsTask: Task<Void, Never>
        var audio: AudioCapture
        /// Keeps the converted audio for the accurate final pass; `nil` when
        /// the file could not be created (the dictation goes on without it).
        var writer: AudioClipWriter?
    }

    private var run: Run?
    private var transcript = TranscriptAssembler()
    private var resultError: (any Error)?
    /// The closed recording of the dictation `finish()` ended, until taken.
    private var recording: RecordedClip?

    func start(locale: Locale, context: TranscriptionContext, audio: AudioCapture) async throws -> TranscriptionSession {
        if run != nil { await cancel() }
        recording?.discard()
        recording = nil
        transcript.reset()
        resultError = nil

        guard let resolved = await SpeechModels.resolve(for: locale) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier(.bcp47))
        }
        let status = await AssetInventory.status(forModules: [resolved.module])
        guard status == .installed else {
            throw TranscriptionError.assetsNotInstalled(resolved.locale.identifier(.bcp47))
        }
        guard let inputFormat = audio.inputFormat else {
            await Diagnostics.record("engine format: input format missing running=\(audio.isRunning)")
            throw TranscriptionError.noCompatibleAudioFormat(.inputFormat)
        }
        let askedAt = Date()
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [resolved.module],
            considering: inputFormat
        )
        let asked = String(format: "%.2f", Date().timeIntervalSince(askedAt))
        guard let analyzerFormat else {
            // Which formats does the module offer at all, and does the answer
            // change without the input format as a hint?
            let offered = await resolved.module.availableCompatibleAudioFormats
            let withoutHint = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [resolved.module])
            await Diagnostics.record("engine format: analyzer format nil after \(asked)s input=\(Self.describe(inputFormat)) module=\(resolved.kind.rawValue) offered=\(offered.map(Self.describe)) withoutHint=\(withoutHint.map(Self.describe) ?? "nil")")
            // A module that offers no format at all, with or without the
            // input as a hint, is not a microphone problem: the model reports
            // `installed` but cannot be loaded (iOS Simulator 27.2, 1 Nov 2026).
            if offered.isEmpty, withoutHint == nil {
                throw TranscriptionError.modelUnavailable(resolved.locale.identifier(.bcp47))
            }
            throw TranscriptionError.noCompatibleAudioFormat(.analyzerFormat)
        }
        guard let converter = AnalyzerInputConversion.makeConverter(from: inputFormat, to: analyzerFormat) else {
            await Diagnostics.record("engine format: converter nil input=\(Self.describe(inputFormat)) analyzer=\(Self.describe(analyzerFormat)) module=\(resolved.kind.rawValue)")
            throw TranscriptionError.noCompatibleAudioFormat(.converter)
        }
        await Diagnostics.record("engine format: input=\(Self.describe(inputFormat)) analyzer=\(Self.describe(analyzerFormat)) module=\(resolved.kind.rawValue) asked=\(asked)s")

        let analysisContext = AnalysisContext()
        if !context.contextualStrings.isEmpty {
            analysisContext.contextualStrings = [.general: context.contextualStrings]
        }

        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let (updateStream, updateContinuation) = AsyncStream.makeStream(
            of: TranscriptUpdate.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        let writer = Self.makeWriter(format: analyzerFormat)
        let pipe = AnalyzerInputPipe(converter: converter, continuation: inputContinuation, writer: writer)

        let analyzer = SpeechAnalyzer(
            modules: [resolved.module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        // Consumes the module's results; started before the analyzer so no
        // early result is missed.
        let resultsTask = Task {
            do {
                try await Self.consumeResults(of: resolved) { text, isFinal in
                    await self.receive(text: text, isFinal: isFinal)
                }
            } catch is CancellationError {
                // Cancelled by `cancel()`.
            } catch {
                self.receive(error: error)
            }
        }
        do {
            try await analyzer.setContext(analysisContext)
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            try await analyzer.start(inputSequence: inputStream)
        } catch {
            // Nothing may outlive a failed start: the results task would keep
            // iterating the module's results and hold this actor.
            resultsTask.cancel()
            pipe.close(flush: false)
            updateContinuation.finish()
            await analyzer.cancelAndFinishNow()
            await writer?.discard()
            throw error
        }

        audio.setSink { buffer, time in
            pipe.send(buffer, at: time)
        }

        run = Run(
            analyzer: analyzer,
            input: pipe,
            updates: updateContinuation,
            resultsTask: resultsTask,
            audio: audio,
            writer: writer
        )
        return TranscriptionSession(locale: resolved.locale, updates: updateStream)
    }

    func finish() async throws -> String {
        guard let run else { throw TranscriptionError.notRunning }
        run.audio.setSink(nil)
        // Yield the converter's held-over audio before ending the input, or
        // the last fragment of speech is dropped.
        run.input.close(flush: true)
        // The pipe is closed, so nothing is appended any more: the file can
        // be completed and closed now, before the final pass opens it.
        recording = await run.writer?.finish()
        if recording == nil, let writer = run.writer {
            await Diagnostics.record("clip not kept failure=\(writer.writeFailure ?? "no audio written")")
        }
        do {
            try await run.analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await run.analyzer.cancelAndFinishNow()
            run.resultsTask.cancel()
            run.updates.finish()
            self.run = nil
            recording?.discard()
            recording = nil
            throw error
        }
        await run.resultsTask.value
        run.updates.finish()
        self.run = nil
        if let resultError, transcript.isEmpty {
            recording?.discard()
            recording = nil
            throw resultError
        }
        // Some locales leave the last words volatile at end of input.
        return transcript.text
    }

    func takeRecording() async -> RecordedClip? {
        defer { recording = nil }
        return recording
    }

    func cancel() async {
        guard let run else { return }
        run.audio.setSink(nil)
        run.input.close(flush: false)
        run.resultsTask.cancel()
        await run.analyzer.cancelAndFinishNow()
        run.updates.finish()
        self.run = nil
        await run.writer?.discard()
        transcript.reset()
    }

    private func receive(text: String, isFinal: Bool) {
        transcript.receive(text: text, isFinal: isFinal)
        run?.updates.yield(TranscriptUpdate(finalized: transcript.finalized, volatile: transcript.volatile))
    }

    /// The writer of the temporary recording, or `nil` (logged) when the file
    /// cannot be created: the final pass is then skipped, nothing else changes.
    private static func makeWriter(format: AVAudioFormat) -> AudioClipWriter? {
        do {
            return try AudioClipWriter(url: AppPaths.newTemporaryRecordingURL(), format: format)
        } catch {
            Task { await Diagnostics.record("clip writer unavailable: \(error.localizedDescription)") }
            return nil
        }
    }

    private func receive(error: any Error) {
        resultError = error
    }

    /// `48000Hz 2ch float32 deinterleaved layout=false`, for the diagnostics log.
    private static func describe(_ format: AVAudioFormat) -> String {
        let common: String = switch format.commonFormat {
        case .pcmFormatFloat32: "float32"
        case .pcmFormatFloat64: "float64"
        case .pcmFormatInt16: "int16"
        case .pcmFormatInt32: "int32"
        default: "other"
        }
        return "\(Int(format.sampleRate))Hz \(format.channelCount)ch \(common) \(format.isInterleaved ? "interleaved" : "deinterleaved") layout=\(format.channelLayout != nil)"
    }

    private static func consumeResults(
        of resolved: ResolvedSpeechModule,
        handler: @Sendable (String, Bool) async -> Void
    ) async throws {
        switch resolved.kind {
        case .speechTranscriber:
            guard let transcriber = resolved.module as? SpeechTranscriber else { return }
            for try await result in transcriber.results {
                await handler(String(result.text.characters), result.isFinal)
            }
        case .dictationTranscriber:
            guard let transcriber = resolved.module as? DictationTranscriber else { return }
            for try await result in transcriber.results {
                await handler(String(result.text.characters), result.isFinal)
            }
        }
    }
}

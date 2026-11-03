import AVFAudio
import Foundation
import HexMobileCore
import Speech

/// The recognition set-ups the app and `asr-bench` compare.
public enum RecognitionVariant: String, CaseIterable, Sendable {
    /// `SpeechTranscriber` with `fastResults`: what the live transcript uses.
    /// Words in about a second, with a smaller context window (Apple's
    /// description of the option: «faster but also less accurate results»).
    case speechFast = "speech-fast"
    /// `SpeechTranscriber` without `fastResults`: the final pass.
    case speechAccurate = "speech-accurate"
    /// `DictationTranscriber` with punctuation: the keyboard dictation model.
    case dictation
}

/// The text of a recognized audio file and how long it took.
public struct ClipTranscription: Sendable, Equatable {
    public var text: String
    /// Wall-clock seconds from the call to the text.
    public var seconds: Double
    /// `speechTranscriber` or `dictationTranscriber`.
    public var module: String
}

public enum ClipTranscriberError: LocalizedError, Equatable, Sendable {
    case unsupportedLocale(String)
    case modelNotInstalled(String)
    case unreadableFile(String)
    case timeout
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedLocale(identifier): "Recognition does not support \(identifier)."
        case let .modelNotInstalled(identifier): "The speech model for \(identifier) is not installed."
        case let .unreadableFile(reason): "The audio file cannot be read: \(reason)"
        case .timeout: "The recognition ran out of time."
        case let .failed(reason): "The recognition failed: \(reason)"
        }
    }
}

/// Recognizes an audio file with Apple's on-device Speech models.
///
/// Used by the app for the accurate final pass over the recording and by
/// `asr-bench` to compare the variants on the same clips. No audio leaves the
/// device.
public enum ClipTranscriber {
    /// Recognizes `file`.
    /// - Parameter timeout: gives up with ``ClipTranscriberError/timeout``
    ///   after this long; `nil` waits as long as it takes.
    public static func transcribe(
        file: URL,
        locale: Locale,
        variant: RecognitionVariant,
        contextualStrings: [String] = [],
        timeout: Duration? = nil
    ) async throws -> ClipTranscription {
        let started = ContinuousClock.now
        let work: @Sendable () async throws -> ClipTranscription = {
            try await run(file: file, locale: locale, variant: variant, contextualStrings: contextualStrings, started: started)
        }
        do {
            if let timeout {
                return try await withDeadline(timeout, operation: work)
            }
            return try await work()
        } catch is DeadlineExceeded {
            throw ClipTranscriberError.timeout
        } catch let error as ClipTranscriberError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClipTranscriberError.failed(describe(error))
        }
    }

    /// Whether the model for the variant is installed for `locale`.
    public static func isInstalled(variant: RecognitionVariant, locale: Locale) async -> Bool {
        guard let resolved = await module(for: variant, locale: locale) else { return false }
        return await AssetInventory.status(forModules: [resolved.module]) == .installed
    }

    /// Downloads and installs the model for the variant, reporting progress in
    /// 0...1. For command line tools: the app has its own install flow
    /// (`SpeechModels.install`) with the reservation of the locale.
    public static func install(
        variant: RecognitionVariant,
        locale: Locale,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let resolved = await module(for: variant, locale: locale) else {
            throw ClipTranscriberError.unsupportedLocale(locale.identifier(.bcp47))
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [resolved.module]) else {
            guard await AssetInventory.status(forModules: [resolved.module]) == .installed else {
                throw ClipTranscriberError.modelNotInstalled(resolved.locale.identifier(.bcp47))
            }
            progress(1)
            return
        }
        let monitor = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { monitor.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    // MARK: - Modules

    struct Resolved: @unchecked Sendable {
        var kind: String
        var locale: Locale
        var module: any SpeechModule
    }

    /// The module for a variant, or `nil` when the locale is not supported.
    /// `speechFast` and `speechAccurate` need `SpeechTranscriber`; `dictation`
    /// is `DictationTranscriber`.
    static func module(for variant: RecognitionVariant, locale: Locale) async -> Resolved? {
        switch variant {
        case .speechFast, .speechAccurate:
            guard SpeechTranscriber.isAvailable,
                  let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
            let reporting: Set<SpeechTranscriber.ReportingOption> = variant == .speechFast
                ? [.volatileResults, .fastResults]
                : []
            let transcriber = SpeechTranscriber(
                locale: supported,
                transcriptionOptions: [],
                reportingOptions: reporting,
                attributeOptions: []
            )
            return Resolved(kind: "speechTranscriber", locale: supported, module: transcriber)
        case .dictation:
            guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
            let transcriber = DictationTranscriber(
                locale: supported,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [],
                attributeOptions: []
            )
            return Resolved(kind: "dictationTranscriber", locale: supported, module: transcriber)
        }
    }

    // MARK: - Run

    private static func run(
        file: URL,
        locale: Locale,
        variant: RecognitionVariant,
        contextualStrings: [String],
        started: ContinuousClock.Instant
    ) async throws -> ClipTranscription {
        guard let resolved = await module(for: variant, locale: locale) else {
            throw ClipTranscriberError.unsupportedLocale(locale.identifier(.bcp47))
        }
        guard await AssetInventory.status(forModules: [resolved.module]) == .installed else {
            throw ClipTranscriberError.modelNotInstalled(resolved.locale.identifier(.bcp47))
        }
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: file)
        } catch {
            throw ClipTranscriberError.unreadableFile(describe(error))
        }

        let analyzer = SpeechAnalyzer(
            modules: [resolved.module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: contextualStrings]
            try await analyzer.setContext(context)
        }

        // The results are consumed from the start, so none is missed.
        let collector = Task { () -> String in
            var assembler = TranscriptAssembler()
            switch resolved.module {
            case let transcriber as SpeechTranscriber:
                for try await result in transcriber.results {
                    assembler.receive(text: String(result.text.characters), isFinal: result.isFinal)
                }
            case let transcriber as DictationTranscriber:
                for try await result in transcriber.results {
                    assembler.receive(text: String(result.text.characters), isFinal: result.isFinal)
                }
            default:
                break
            }
            return assembler.text
        }

        return try await withTaskCancellationHandler {
            do {
                if let last = try await analyzer.analyzeSequence(from: audioFile) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                let text = try await collector.value
                let elapsed = started.duration(to: .now)
                return ClipTranscription(
                    text: text,
                    seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                    module: resolved.kind
                )
            } catch {
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(error.localizedDescription)"
    }
}

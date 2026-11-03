import Foundation
import HexMobileSpeech

/// A transcription back end. v1 ships ``OnDeviceSpeechEngine`` (Apple
/// `SpeechAnalyzer`); a future relay engine (audio streamed to Hex on a Mac)
/// can conform to the same protocol without touching the UI or text pipeline.
protocol TranscriptionEngine: AnyObject, Sendable {
    /// Stable identifier stored with each dictation (e.g. `on-device`).
    nonisolated var identifier: String { get }

    /// Starts transcribing audio from `audio`, which must already be running.
    /// - Returns: the live session (resolved locale and transcript updates).
    func start(locale: Locale, context: TranscriptionContext, audio: AudioCapture) async throws -> TranscriptionSession

    /// Stops consuming audio, waits for the final results and returns the
    /// full transcript.
    func finish() async throws -> String

    /// Stops immediately and discards the transcript.
    func cancel() async

    /// The recording of the dictation `finish()` has just ended: the audio the
    /// recognizer received, as a closed file, for the accurate final pass.
    /// The caller owns the file and discards it (or keeps it, with the opt-in
    /// clips). `nil` when nothing was recorded or the file could not be
    /// written; asking again returns `nil`.
    func takeRecording() async -> RecordedClip?
}

/// Hints for the recognizer.
struct TranscriptionContext: Sendable, Equatable {
    /// Terms to bias recognition toward (Hex vocabulary terms).
    var contextualStrings: [String] = []
}

/// A running transcription.
struct TranscriptionSession: Sendable {
    /// The locale actually used by the recognizer.
    var locale: Locale
    /// Live transcript updates; finishes when the engine finishes or cancels.
    var updates: AsyncStream<TranscriptUpdate>
}

/// The transcript so far: finalized text plus the volatile tail that the
/// recognizer may still revise.
struct TranscriptUpdate: Sendable, Equatable {
    var finalized: String
    var volatile: String
}

enum TranscriptionError: LocalizedError, Equatable {
    /// Which of the three steps that settle the audio format came back empty.
    enum AudioFormatStep: String, Sendable {
        /// The capture has no input format (the engine is not running).
        case inputFormat
        /// `SpeechAnalyzer.bestAvailableAudioFormat` returned `nil`.
        case analyzerFormat
        /// No converter from the input format to the analyzer's.
        case converter
    }

    case unsupportedLocale(String)
    case assetsNotInstalled(String)
    case noCompatibleAudioFormat(AudioFormatStep)
    /// The model reports `installed` but the system offers no audio format for
    /// it and refuses to prepare it. On iOS Simulator 27.2 this is the
    /// `DictationTranscriber` state (1 Nov 2026: `availableCompatibleAudioFormats`
    /// empty, `prepareToAnalyze` fails with `SFSpeechErrorDomain` 4 "Model not
    /// available"), so the cause is not the microphone format.
    case modelUnavailable(String)
    /// The system returned no installation request for a model that is not
    /// installed, so there is nothing to download.
    case assetInstallUnavailable(String)
    case notRunning

    var errorDescription: String? {
        switch self {
        case let .unsupportedLocale(identifier):
            String(localized: "On-device recognition does not support \(identifier). Choose another language in Settings.")
        case let .assetsNotInstalled(identifier):
            String(localized: "The speech model for \(identifier) is not installed yet. Install it from Settings or the Dictate screen.")
        case .noCompatibleAudioFormat:
            String(localized: "The microphone format is not compatible with the speech recognizer.")
        case let .modelUnavailable(identifier):
            String(localized: "The speech model for \(identifier) is installed but cannot be loaded on this device.")
        case let .assetInstallUnavailable(identifier):
            String(localized: "The system did not offer the speech model for \(identifier) for download. Try again later.")
        case .notRunning:
            String(localized: "No dictation is running.")
        }
    }
}

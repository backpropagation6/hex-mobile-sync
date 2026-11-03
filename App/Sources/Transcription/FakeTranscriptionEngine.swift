#if DEBUG
import AVFAudio
import Foundation
import HexMobileSpeech

/// `-HexMobileFakeEngine YES` (Debug builds only): an engine that hears nothing
/// and "transcribes" a fixed sentence, so the simulator, which has no speech
/// model (`modelUnavailable`), can run a whole dictation: start, live words,
/// stop, cancel, the payload offered to the keyboard. Never the real recognizer.
actor FakeTranscriptionEngine: TranscriptionEngine {
    nonisolated let identifier = "debug-fake"

    static let sentence = "prova di dettatura finta dal simulatore"

    private var continuation: AsyncStream<TranscriptUpdate>.Continuation?
    private var ticker: Task<Void, Never>?
    private var writer: AudioClipWriter?
    private var recording: RecordedClip?

    func start(locale: Locale, context: TranscriptionContext, audio: AudioCapture) async throws -> TranscriptionSession {
        ticker?.cancel()
        recording?.discard()
        recording = nil
        await writer?.discard()
        writer = Self.makeSilentWriter()
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptUpdate.self)
        self.continuation = continuation
        let words = Self.sentence.split(separator: " ").map(String.init)
        ticker = Task {
            for count in 1...words.count {
                try? await Task.sleep(for: .milliseconds(600))
                if Task.isCancelled { return }
                continuation.yield(TranscriptUpdate(finalized: words.prefix(count).joined(separator: " "), volatile: ""))
            }
        }
        return TranscriptionSession(locale: locale, updates: stream)
    }

    func finish() async throws -> String {
        ticker?.cancel()
        continuation?.finish()
        continuation = nil
        recording = await writer?.finish()
        writer = nil
        return Self.sentence
    }

    func takeRecording() async -> RecordedClip? {
        defer { recording = nil }
        return recording
    }

    func cancel() async {
        ticker?.cancel()
        continuation?.finish()
        continuation = nil
        await writer?.discard()
        writer = nil
    }

    /// A real file in the analyzer's usual format (16 kHz mono 16-bit), so the
    /// simulator exercises the same file life cycle as a real dictation:
    /// written, read by the final pass, deleted. One second of silence, or the
    /// audio of `-HexMobileFakeClip` when given.
    private static func makeSilentWriter() -> AudioClipWriter? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let writer = try? AudioClipWriter(url: AppPaths.newTemporaryRecordingURL(), format: format)
        else { return nil }
        if let path = LaunchOptions.fakeClipPath {
            return copy(clipAt: URL(fileURLWithPath: path), into: writer, format: format) ? writer : nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000) else { return nil }
        buffer.frameLength = 16_000
        writer.append(buffer)
        return writer
    }

    /// Feeds the frames of `clip` to `writer`, in half-second buffers. The
    /// clip must already be in `format`: a mismatch fails instead of converting,
    /// so a proof never runs on audio other than the one named.
    private static func copy(clipAt clip: URL, into writer: AudioClipWriter, format: AVAudioFormat) -> Bool {
        guard let file = try? AVAudioFile(forReading: clip, commonFormat: .pcmFormatInt16, interleaved: true),
              file.processingFormat.sampleRate == format.sampleRate,
              file.processingFormat.channelCount == format.channelCount
        else {
            note("fake clip not usable path=\(clip.lastPathComponent)")
            return false
        }
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000) else { return false }
            do { try file.read(into: buffer, frameCount: 8_000) } catch { return false }
            if buffer.frameLength == 0 { break }
            writer.append(buffer)
        }
        note("fake clip loaded path=\(clip.lastPathComponent) seconds=\(String(format: "%.1f", Double(file.length) / format.sampleRate))")
        return true
    }

    private static func note(_ line: String) {
        Task { @MainActor in Diagnostics.record(line) }
    }
}

/// `-HexMobileFakeFinalPass ok|slow|fail|short|empty` (Debug builds only): a
/// final pass that does not read the audio, to walk each outcome of the real
/// one (the simulator cannot load the Italian speech model). `ok` returns the
/// sentence with a capital and a full stop.
struct FakeFinalPassEngine: FinalPassEngine {
    let mode: String

    var name: String { "debug-fake-\(mode)" }

    func transcribe(fileURL: URL, locale: Locale, contextualStrings: [String]) async throws -> String {
        // The file must exist: the lifecycle under test is the real one.
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        switch mode {
        case "slow":
            try await Task.sleep(for: .seconds(60))
            return ""
        case "fail":
            throw CocoaError(.fileReadCorruptFile)
        case "short":
            return "prova"
        case "empty":
            return ""
        case "messy":
            // What the recognizer hands over: no punctuation, hesitations, a
            // spoken correction. Exercises the cleanup with the real model.
            try await Task.sleep(for: .milliseconds(400))
            return "ehm allora devo ricordarmi di chiamare Mauro domani no anzi dopodomani per la demo del gestionale"
        default:
            try await Task.sleep(for: .milliseconds(400))
            return "Prova di dettatura finta dal simulatore."
        }
    }
}
#endif

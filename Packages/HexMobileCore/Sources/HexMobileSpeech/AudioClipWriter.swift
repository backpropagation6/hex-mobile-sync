import AVFAudio
import Foundation

/// A finished recording on disk.
public struct RecordedClip: Sendable, Equatable {
    public var url: URL
    public var seconds: Double
    public var sampleRate: Double
    public var channels: Int

    /// Deletes the file. Safe to call twice.
    public func discard() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Writes the audio the analyzer receives (already converted, normally
/// 16 kHz mono 16-bit) to a CAF file while the dictation records.
///
/// ``append(_:)`` is called from the audio thread: it only hands the buffer to
/// a serial queue, which does the file I/O. ``finish()`` waits for that queue,
/// so the file is complete and closed when it returns.
public final class AudioClipWriter: @unchecked Sendable {
    public let url: URL

    private struct Pending: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private let queue = DispatchQueue(label: "io.github.hexmobile.clip-writer", qos: .utility)
    private let format: AVAudioFormat
    private let maxFrames: AVAudioFramePosition
    // Confined to `queue`.
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var failure: String?

    /// - Parameter maxSeconds: stops writing after this much audio, so a
    ///   dictation left running cannot fill the disk (15 minutes is ~29 MB).
    public init(url: URL, format: AVAudioFormat, maxSeconds: Double = 900) throws {
        self.url = url
        self.format = format
        maxFrames = AVAudioFramePosition(maxSeconds * format.sampleRate)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    /// Queues one buffer. The buffer must not be modified afterwards (the
    /// converter hands out owned buffers).
    public func append(_ buffer: AVAudioPCMBuffer) {
        let pending = Pending(buffer: buffer)
        queue.async { [self] in
            guard failure == nil, let file, frames < maxFrames else { return }
            do {
                try file.write(from: pending.buffer)
                frames += AVAudioFramePosition(pending.buffer.frameLength)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Waits for the queued buffers, closes the file and returns it. `nil`
    /// (and the file deleted) when nothing was written or a write failed.
    public func finish() async -> RecordedClip? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let written = frames
                let failed = failure != nil
                file = nil // closes the file
                guard !failed, written > 0 else {
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: RecordedClip(
                    url: url,
                    seconds: Double(written) / format.sampleRate,
                    sampleRate: format.sampleRate,
                    channels: Int(format.channelCount)
                ))
            }
        }
    }

    /// Closes the file and deletes it.
    public func discard() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                file = nil
                try? FileManager.default.removeItem(at: url)
                continuation.resume()
            }
        }
    }

    /// The reason a write failed, if one did (read after ``finish()``).
    public var writeFailure: String? {
        queue.sync { failure }
    }
}

import AVFAudio
import Foundation
import HexMobileSpeech
import Speech

/// Turns microphone buffers (hardware format) into `AnalyzerInput` values in
/// the analyzer's format.
///
/// Not thread-safe on its own: ``AnalyzerInputPipe`` serializes every call.
protocol AnalyzerInputConverting: AnyObject {
    /// Converts one tap buffer. The tap buffer is only valid during the call.
    func inputs(from buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> [AnalyzerInput]
    /// Converts audio the converter still holds (resampler tail, held-over
    /// samples). Call once, after the last buffer and before finishing the input.
    func flush() -> [AnalyzerInput]
}

enum AnalyzerInputConversion {
    /// The best converter for this OS: `AnalyzerInputConverter` on iOS 27+,
    /// an `AVAudioConverter`-based fallback on iOS 26.
    static func makeConverter(
        from inputFormat: AVAudioFormat,
        to analyzerFormat: AVAudioFormat
    ) -> (any AnalyzerInputConverting)? {
        // Not `SystemAnalyzerInputConverter`: on iOS 27.2 it held the audio
        // until `flush()`, so no live (volatile) result arrived while
        // recording (1 Nov 2026, one transcript update per dictation).
        return AVAudioAnalyzerInputConverter(from: inputFormat, to: analyzerFormat)
    }

    /// A copy of `buffer` that the caller owns. Tap buffers are reused by the
    /// engine as soon as the tap block returns, so anything that keeps a buffer
    /// beyond the call (the iOS 27 converter may hold samples over to a later
    /// call) must get a copy.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let from = source[index].mData, let to = destination[index].mData else { continue }
            memcpy(to, from, Int(min(source[index].mDataByteSize, destination[index].mDataByteSize)))
        }
        return copy
    }
}

/// Connects the audio thread to the analyzer input stream.
///
/// Every conversion, the final flush and the end of the stream happen under
/// one lock, so no buffer can be yielded after the flushed tail or after the
/// stream finished, even when the audio thread is inside ``send(_:at:)`` while
/// the engine finishes.
///
/// The converted buffers also go to `writer`, which keeps them in a file for
/// the accurate final pass. The writer does its I/O on its own queue, never on
/// the audio thread, and gets the flushed tail too.
final class AnalyzerInputPipe: @unchecked Sendable {
    // Guarded by `lock`.
    private let converter: any AnalyzerInputConverting
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let writer: AudioClipWriter?
    private var isClosed = false
    private let lock = NSLock()

    init(
        converter: any AnalyzerInputConverting,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        writer: AudioClipWriter? = nil
    ) {
        self.converter = converter
        self.continuation = continuation
        self.writer = writer
    }

    /// Audio thread: converts and forwards one tap buffer.
    func send(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        for input in converter.inputs(from: buffer, at: time) {
            writer?.append(input.buffer)
            continuation.yield(input)
        }
    }

    /// Ends the input. With `flush`, the converter's held-over audio is
    /// yielded first, so the last words are not cut. Idempotent.
    func close(flush: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        if flush {
            for input in converter.flush() {
                writer?.append(input.buffer)
                continuation.yield(input)
            }
        }
        continuation.finish()
    }
}

/// iOS 27+: Speech's own converter.
@available(iOS 27, *)
final class SystemAnalyzerInputConverter: AnalyzerInputConverting {
    private let converter: AnalyzerInputConverter

    init(analyzerFormat: AVAudioFormat) {
        converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
    }

    func inputs(from buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> [AnalyzerInput] {
        // The converter may retain the buffer across calls ("Do not reuse or
        // modify this buffer"), while the engine reuses tap buffers: hand it
        // a copy.
        guard let owned = AnalyzerInputConversion.copy(buffer) else { return [] }
        return (try? converter.convert(owned, at: time)) ?? []
    }

    func flush() -> [AnalyzerInput] {
        (try? converter.flush()) ?? []
    }
}

/// iOS 26 fallback: `AVAudioConverter` to the analyzer format. Always copies,
/// because tap buffers are reused by the engine after the tap returns.
final class AVAudioAnalyzerInputConverter: AnalyzerInputConverting {
    private let converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
        ratio = outputFormat.sampleRate / inputFormat.sampleRate
        if inputFormat == outputFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
            self.converter = converter
        }
    }

    func inputs(from buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> [AnalyzerInput] {
        guard let converted = convert(buffer) else { return [] }
        return [AnalyzerInput(buffer: converted)]
    }

    func flush() -> [AnalyzerInput] {
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)
        else { return [] }
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        converter.reset()
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return [] }
        return [AnalyzerInput(buffer: output)]
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return AnalyzerInputConversion.copy(buffer) }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

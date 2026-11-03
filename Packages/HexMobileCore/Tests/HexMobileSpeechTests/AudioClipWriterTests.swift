import AVFAudio
import Foundation
import Testing
@testable import HexMobileSpeech

@Suite("AudioClipWriter")
struct AudioClipWriterTests {
    /// What the analyzer receives on the phone: 16 kHz, mono, 16-bit.
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "hexmobile-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "clip.caf")
    }

    /// `frames` samples counting up from `start`.
    static func buffer(frames: Int, start: Int16 = 0) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.int16ChannelData![0]
        for index in 0..<frames { samples[index] = start &+ Int16(truncatingIfNeeded: index) }
        return buffer
    }

    @Test("buffers written in order come back whole when the file is finished")
    func roundTrip() async throws {
        let url = Self.tempURL()
        let writer = try AudioClipWriter(url: url, format: Self.format)
        writer.append(Self.buffer(frames: 1600, start: 0))
        writer.append(Self.buffer(frames: 1600, start: 1600))
        writer.append(Self.buffer(frames: 800, start: 3200))
        let clip = try #require(await writer.finish())
        defer { clip.discard() }

        #expect(clip.url == url)
        #expect(clip.sampleRate == 16_000)
        #expect(clip.channels == 1)
        #expect(abs(clip.seconds - 0.25) < 1e-9)

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        #expect(file.length == 4000)
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4000)!
        try file.read(into: read)
        let samples = read.int16ChannelData![0]
        #expect(samples[0] == 0)
        #expect(samples[1599] == 1599)
        #expect(samples[1600] == 1600)
        #expect(samples[3999] == 3999)
    }

    @Test("a writer that got no audio returns nil and leaves no file")
    func nothingWritten() async throws {
        let url = Self.tempURL()
        let writer = try AudioClipWriter(url: url, format: Self.format)
        #expect(await writer.finish() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("discard closes and deletes the file")
    func discard() async throws {
        let url = Self.tempURL()
        let writer = try AudioClipWriter(url: url, format: Self.format)
        writer.append(Self.buffer(frames: 1600))
        await writer.discard()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("audio past the limit is not written")
    func limit() async throws {
        let url = Self.tempURL()
        // One second of audio at most.
        let writer = try AudioClipWriter(url: url, format: Self.format, maxSeconds: 1)
        for _ in 0..<5 { writer.append(Self.buffer(frames: 8000)) }
        let clip = try #require(await writer.finish())
        defer { clip.discard() }
        // The buffer that crosses the limit is the last one written.
        #expect(clip.seconds <= 1.5)
        #expect(clip.seconds >= 1)
    }

    @Test("a clip is deleted once, and deleting it again is harmless")
    func discardTwice() async throws {
        let writer = try AudioClipWriter(url: Self.tempURL(), format: Self.format)
        writer.append(Self.buffer(frames: 1600))
        let clip = try #require(await writer.finish())
        clip.discard()
        clip.discard()
        #expect(!FileManager.default.fileExists(atPath: clip.url.path))
    }
}

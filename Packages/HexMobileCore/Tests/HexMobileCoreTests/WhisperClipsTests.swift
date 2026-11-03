import Foundation
import Testing
@testable import HexMobileCore

@Suite("Whisper pieces")
struct WhisperClipsTests {
    private let rate = WhisperClips.sampleRate

    /// A loud stretch for `seconds` (a constant level: the cut looks at energy
    /// only, and this is cheap to make in a debug build), or silence when
    /// `loud` is false.
    private func part(_ seconds: Double, loud: Bool) -> [Float] {
        [Float](repeating: loud ? 0.3 : 0, count: Int(seconds * Double(rate)))
    }

    private func seconds(_ range: Range<Int>) -> Double {
        Double(range.count) / Double(rate)
    }

    // MARK: Budget

    @Test("the piece length follows the prompt: 98 tokens leave 15 s")
    func budget() {
        #expect(abs(WhisperClips.maxPieceSeconds(promptTokens: 98) - 15.0) < 0.001)
        #expect(abs(WhisperClips.maxPieceSeconds(promptTokens: 100) - 14.75) < 0.001)
        // No prompt: the window of the model is the limit, a little under it.
        #expect(WhisperClips.maxPieceSeconds(promptTokens: 0) <= WhisperClips.maximumPieceSeconds)
        #expect(WhisperClips.maxPieceSeconds(promptTokens: 0) > 25)
        // A prompt that eats the context: never below the floor, never negative.
        #expect(WhisperClips.maxPieceSeconds(promptTokens: 400) == WhisperClips.minimumPieceSeconds)
        #expect(WhisperClips.maxPieceSeconds(promptTokens: -5) == WhisperClips.maxPieceSeconds(promptTokens: 0))
    }

    @Test("the planned count, without audio: one up to the maximum, then by the typical fill")
    func plannedPieces() {
        #expect(WhisperClips.plannedPieces(recordingSeconds: 0, promptTokens: 98) == 0)
        #expect(WhisperClips.plannedPieces(recordingSeconds: 4.8, promptTokens: 98) == 1)
        #expect(WhisperClips.plannedPieces(recordingSeconds: 15.0, promptTokens: 98) == 1)
        #expect(WhisperClips.plannedPieces(recordingSeconds: 15.1, promptTokens: 98) == 2)
        // Counts the Mac made with a 14.75 s maximum (a 100-token prompt):
        // 24.1 s in 2 pieces, 42.4 s in 4.
        #expect(WhisperClips.plannedPieces(recordingSeconds: 24.1, promptTokens: 100) == 2)
        #expect(WhisperClips.plannedPieces(recordingSeconds: 42.4, promptTokens: 100) == 4)
    }

    // MARK: Splitting

    @Test("nothing to cut: empty, short, and exactly the maximum are one piece")
    func noCut() {
        #expect(WhisperClips.split(samples: [], maxSeconds: 15).isEmpty)
        let short = part(4.8, loud: true)
        #expect(WhisperClips.split(samples: short, maxSeconds: 15) == [0..<short.count])
        let exact = part(15, loud: true)
        #expect(WhisperClips.split(samples: exact, maxSeconds: 15) == [0..<exact.count])
    }

    @Test("a cut falls in the pause, not in the speech")
    func cutInPause() {
        // 11 s of speech, a 0.6 s pause, 12 s of speech: the pause is at 11.0 to 11.6 s.
        let samples = part(11, loud: true) + part(0.6, loud: false) + part(12, loud: true)
        let pieces = WhisperClips.split(samples: samples, maxSeconds: 15)
        #expect(pieces.count == 2)
        let cut = Double(pieces[0].upperBound) / Double(rate)
        #expect(cut >= 11.0 && cut <= 11.6)
        #expect(pieces[0].upperBound == pieces[1].lowerBound)
    }

    @Test("with several pauses the cut takes the longest one in the allowed stretch, not the last")
    func quietestPause() {
        // Pauses at 4.0 s (before the allowed stretch 7.5 to 15 s), 9.0 s (0.8 s long)
        // and 13.0 s (0.2 s: shorter than the 240 ms the cut looks for).
        let samples = part(4, loud: true) + part(0.5, loud: false)
            + part(4.5, loud: true) + part(0.8, loud: false)
            + part(3.2, loud: true) + part(0.2, loud: false)
            + part(12, loud: true)
        let pieces = WhisperClips.split(samples: samples, maxSeconds: 15)
        let cut = Double(pieces[0].upperBound) / Double(rate)
        #expect(cut >= 9.0 && cut <= 9.8)
    }

    @Test("a constant level, with no pause at all, is still cut and the pieces fit")
    func noPause() {
        let samples = part(40, loud: true)
        let pieces = WhisperClips.split(samples: samples, maxSeconds: 15)
        #expect(pieces.count == 3)
        for piece in pieces { #expect(seconds(piece) <= 15.001) }
    }

    @Test("a short remainder is never left as a tiny last piece (it would not be read)")
    func noTinyTail() {
        // 15.3 s with a 15 s maximum: two pieces, the last at least half of the maximum.
        let samples = part(15.3, loud: true)
        let pieces = WhisperClips.split(samples: samples, maxSeconds: 15)
        #expect(pieces.count == 2)
        #expect(seconds(pieces[0]) >= 7.5)
        #expect(seconds(pieces[1]) >= 7.5)
    }

    @Test("pieces follow one another, cover the whole recording and stay inside the bounds")
    func invariants() {
        let maxSeconds = 15.0
        var length = 8.0
        while length < 45 {
            // Speech with a pause of 0.4 s every 5.3 s, so cuts have something to find.
            var samples: [Float] = []
            var spoken = 0.0
            while spoken < length {
                let chunk = min(5.3, length - spoken)
                samples += part(chunk, loud: true)
                spoken += chunk
                if spoken < length {
                    let pause = min(0.4, length - spoken)
                    samples += part(pause, loud: false)
                    spoken += pause
                }
            }
            let pieces = WhisperClips.split(samples: samples, maxSeconds: maxSeconds)
            #expect(pieces.first?.lowerBound == 0, "length \(length)")
            #expect(pieces.last?.upperBound == samples.count, "length \(length)")
            for (previous, next) in zip(pieces, pieces.dropFirst()) {
                #expect(previous.upperBound == next.lowerBound, "length \(length)")
            }
            if pieces.count > 1 {
                for piece in pieces {
                    #expect(seconds(piece) <= maxSeconds + 0.001, "length \(length)")
                    #expect(seconds(piece) >= maxSeconds / 2 - 0.001, "length \(length)")
                }
            } else {
                #expect(length <= maxSeconds + 0.05, "length \(length)")
            }
            length += 1.7
        }
    }

    @Test("a recording slightly over the maximum, by a fraction of a frame, is not split into nothing")
    func fractionOfFrame() {
        let count = Int(15 * Double(rate)) + 100
        let pieces = WhisperClips.split(samples: [Float](repeating: 0.2, count: count), maxSeconds: 15)
        #expect(pieces == [0..<count])
    }
}

import Foundation

/// Cuts a recording into the pieces Whisper reads one at a time.
///
/// Why: the Whisper decoder has a context of 224 tokens and the prompt, the
/// four control tokens and the text it writes share it. A window of 30 s of
/// speech is about 150 to 220 tokens. With the vocabulary prompt (up to 100
/// tokens) the context is full after about 20 s, and WhisperKit then drops the
/// rest of the window: on 2 Nov 2026 a 42 s dictation on the phone lost one to
/// two sentences around second 30. Cutting the recording where the speaker
/// pauses, into pieces that fit the token budget, keeps every piece well
/// inside the context. Pure code: no model needed, so it is tested here.
public enum WhisperClips {
    public static let sampleRate = 16_000

    /// Tokens of the decoder context (`Constants.maxTokenContext` of WhisperKit
    /// 1.1.1: 448 / 2).
    public static let decoderContextTokens = 224

    /// Tokens in front of the text: `startofprev`, then after the prompt `startoftranscript`,
    /// language, task and `notimestamps` (`TextDecoder.prefillDecoderInputs`).
    public static let controlTokens = 5

    /// The last position is the end-of-text token.
    public static let endTokens = 1

    /// Tokens per second of speech the budget plans for. Italian measured at
    /// 5 to 6.1 tokens per second (phone, 2 Nov 2026; Mac, synthetic voice):
    /// 8 leaves a margin of about 30 % for a fast speaker.
    public static let plannedTokensPerSecond = 8.0

    /// Bounds of a piece, in seconds. Above the upper one the window is the
    /// model's (30 s) and nothing is gained; below the lower one a piece costs
    /// a whole encoder pass for a few words.
    public static let minimumPieceSeconds = 8.0
    public static let maximumPieceSeconds = 28.0

    /// The longest piece of speech that still leaves room in the decoder
    /// context, for a prompt of `promptTokens`.
    ///
    /// `(224 - 5 - 1 - prompt) / 8`: with a 98-token prompt, 15.0 s.
    public static func maxPieceSeconds(promptTokens: Int) -> Double {
        let free = decoderContextTokens - controlTokens - endTokens - max(0, promptTokens)
        let seconds = Double(free) / plannedTokensPerSecond
        return min(max(seconds, minimumPieceSeconds), maximumPieceSeconds)
    }

    /// How many pieces a recording of `seconds` will come to, without the
    /// audio (a plan for the time estimate, not a measure; the real count is in
    /// the log, `whisper pieces n=`).
    ///
    /// Up to the maximum it is one, exactly. Above it the cuts fall between
    /// half and the whole of the maximum, so the count is the recording over
    /// ``typicalFill`` times the maximum, rounded up.
    public static func plannedPieces(recordingSeconds seconds: Double, promptTokens: Int) -> Int {
        guard seconds > 0 else { return 0 }
        let maxSeconds = maxPieceSeconds(promptTokens: promptTokens)
        guard seconds > maxSeconds else { return 1 }
        return Int((seconds / (maxSeconds * typicalFill)).rounded(.up))
    }

    /// Pieces come out at about this share of their maximum. Measured on the
    /// synthetic clips with a 14.75 s maximum: 24.1 s in 2 pieces (0.82),
    /// 42.4 s in 4 (0.72), 61.7 s in 6 (0.70), 104.2 s in 10 (0.71). 0.85 gives
    /// the right count up to 40 s, where the decision is made, and one less on
    /// the longer ones, which no budget allows anyway.
    static let typicalFill = 0.85

    // MARK: - Splitting

    /// Frame of the energy measure, in samples (20 ms).
    static let frameSamples = sampleRate / 50
    /// The pause is searched as the quietest stretch of this many frames (240 ms):
    /// a pause between sentences, not the dip between two syllables.
    static let pauseFrames = 12

    /// The pieces of `samples` (16 kHz mono), as sample ranges that follow one
    /// another with no gap.
    ///
    /// A recording up to `maxSeconds` is one piece. A longer one is cut, from
    /// the start, in the quietest 240 ms found between half of `maxSeconds`
    /// and `maxSeconds` after the previous cut, and every piece keeps at least
    /// half of `maxSeconds` (the last one included: a tail shorter than a
    /// second would not be read at all, WhisperKit stops a second before the
    /// end of a clip). In continuous speech with no pause the cut can fall
    /// inside a word.
    public static func split(samples: [Float], maxSeconds: Double) -> [Range<Int>] {
        guard !samples.isEmpty else { return [] }
        let maxFrames = max(Int(maxSeconds * 50), 2 * pauseFrames)
        let frameCount = samples.count / frameSamples
        guard frameCount > maxFrames else { return [0..<samples.count] }

        let energy = frameEnergies(samples, frameCount: frameCount)
        let minFrames = maxFrames / 2
        var pieces: [Range<Int>] = []
        var startFrame = 0
        while frameCount - startFrame > maxFrames {
            // The cut keeps `minFrames` at both ends; the second bound
            // is never below the first because the remainder exceeds `maxFrames`.
            let lowest = startFrame + minFrames
            let highest = min(startFrame + maxFrames, frameCount - minFrames)
            let cut = quietestFrame(in: lowest...max(lowest, highest), energy: energy)
            pieces.append((startFrame * frameSamples)..<(cut * frameSamples))
            startFrame = cut
        }
        pieces.append((startFrame * frameSamples)..<samples.count)
        return pieces
    }

    /// Root-mean-square of each 20 ms frame.
    static func frameEnergies(_ samples: [Float], frameCount: Int) -> [Float] {
        var energy = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<frameCount {
                var sum: Float = 0
                for index in (frame * frameSamples)..<((frame + 1) * frameSamples) {
                    sum += buffer[index] * buffer[index]
                }
                energy[frame] = (sum / Float(frameSamples)).squareRoot()
            }
        }
        return energy
    }

    /// The frame at the middle of the quietest `pauseFrames` stretch whose
    /// middle lies in `range`; on a tie the later one (longer pieces).
    static func quietestFrame(in range: ClosedRange<Int>, energy: [Float]) -> Int {
        let half = pauseFrames / 2
        var best = range.upperBound
        var bestMean = Float.greatestFiniteMagnitude
        for center in range {
            let from = max(0, center - half)
            let to = min(energy.count, center + half)
            guard to > from else { continue }
            var sum: Float = 0
            for frame in from..<to { sum += energy[frame] }
            let mean = sum / Float(to - from)
            if mean <= bestMean {
                bestMean = mean
                best = center
            }
        }
        return best
    }
}

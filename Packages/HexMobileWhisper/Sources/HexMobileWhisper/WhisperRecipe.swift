import Foundation
import HexMobileCore
import WhisperKit

/// How Hex Mobile asks WhisperKit for a text: the one place where the
/// decoding options are built and a recording is cut into pieces.
///
/// The app (`WhisperModelHolder`) and `tools/whisper-bench` both call
/// ``transcribe(kit:samples:language:terms:splitIntoPieces:isolation:)``; there is
/// no second copy of these options anywhere. What differs between the phone
/// and the Mac is only how the model was loaded (the compute units).
///
/// The recipe, and why:
/// - temperature 0 with the library's usual fallbacks; the deadline of the
///   caller bounds the time;
/// - the language of the locale (`nil` detects it);
/// - no timestamps (`withoutTimestamps`): one window per piece, so a window
///   is never decoded twice from a timestamp inside it;
/// - the vocabulary as a prompt of at most ``WhisperPromptBuilder/tokenCap``
///   tokens;
/// - a recording longer than the decoder can read in one window is cut into
///   pieces at the speaker's pauses (``WhisperClips``) and handed to WhisperKit
///   as `clipTimestamps`, in one call. Without that, the window of 30 s ran out
///   of its 224 tokens (prompt included) and WhisperKit dropped the rest of it.
public enum WhisperRecipe {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The loaded model has no tokenizer.
        case noTokenizer

        public var description: String {
            switch self {
            case .noTokenizer: "no-tokenizer"
            }
        }
    }

    /// What will be decoded: the prompt, and where the recording is cut.
    public struct Plan: Sendable, Equatable {
        public var prompt: WhisperPrompt
        /// Sample ranges (16 kHz) that follow one another. One entry: the
        /// recording is read as it is, in WhisperKit's own windows.
        public var pieces: [Range<Int>]
        public var maxPieceSeconds: Double
        public var recordingSeconds: Double

        public init(prompt: WhisperPrompt, pieces: [Range<Int>], maxPieceSeconds: Double, recordingSeconds: Double) {
            self.prompt = prompt
            self.pieces = pieces
            self.maxPieceSeconds = maxPieceSeconds
            self.recordingSeconds = recordingSeconds
        }

        /// `whisper pieces n=4 max=15.0s prompt=98 rec=42.4s`
        public var logLine: String {
            "whisper pieces n=\(pieces.count) max=\(String(format: "%.1f", maxPieceSeconds))s prompt=\(prompt.tokens.count) rec=\(String(format: "%.1f", recordingSeconds))s"
        }
    }

    /// What the library measured for one run.
    public struct Timings: Sendable, Equatable {
        public var windows: Int
        /// Decoder steps (`totalDecodingLoops`): the tokens written plus the prompt and control tokens fed in again for every window.
        public var steps: Int
        public var encodingSeconds: Double
        public var decodingSeconds: Double
        public var pipelineSeconds: Double

        public init(windows: Int, steps: Int, encodingSeconds: Double, decodingSeconds: Double, pipelineSeconds: Double) {
            self.windows = windows
            self.steps = steps
            self.encodingSeconds = encodingSeconds
            self.decodingSeconds = decodingSeconds
            self.pipelineSeconds = pipelineSeconds
        }

        /// `whisper timings windows=4 steps=633 enc=0.90s dec=5.80s pipeline=7.10s`
        public var logLine: String {
            "whisper timings windows=\(windows) steps=\(steps) enc=\(String(format: "%.2f", encodingSeconds))s dec=\(String(format: "%.2f", decodingSeconds))s pipeline=\(String(format: "%.2f", pipelineSeconds))s"
        }
    }

    public struct Output: Sendable {
        public var text: String
        public var plan: Plan
        public var timings: Timings
        /// How the pieces were put together; `nil` when the text is the library's own
        /// (one window, or segments that are not one per window).
        public var joined: WhisperClips.Joined?
    }

    // MARK: - Options

    /// The decoding options. The single place that builds them.
    ///
    /// - Parameters:
    ///   - language: the language code (`it`); `nil` lets the model detect it.
    ///   - promptTokens: the vocabulary prompt; empty for none.
    ///   - pieces: the cut of the recording; one piece (or none) leaves the
    ///     reading to the library's 30 s windows.
    public static func decodingOptions(language: String?, promptTokens: [Int], pieces: [Range<Int>]) -> DecodingOptions {
        var options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens.isEmpty ? nil : promptTokens
        )
        if pieces.count > 1 {
            // Pairs of start and end, in seconds. Each boundary is the same
            // number for the end of one piece and the start of the next.
            let rate = Float(WhisperClips.sampleRate)
            options.clipTimestamps = pieces.flatMap { [Float($0.lowerBound) / rate, Float($0.upperBound) / rate] }
        }
        return options
    }

    // MARK: - Plan

    /// The prompt for `terms` and the cut of `samples` for that prompt.
    ///
    /// - Parameters:
    ///   - encode: the Whisper tokenizer with the special tokens filtered out.
    ///   - splitIntoPieces: `false` reads the recording in one go, as the
    ///     first version did (to reproduce the cut text in the bench).
    public static func plan(
        samples: [Float],
        terms: [String],
        splitIntoPieces: Bool = true,
        encode: (String) -> [Int]
    ) -> Plan {
        let prompt = WhisperPromptBuilder.build(terms: terms, encode: encode)
        let maxSeconds = WhisperClips.maxPieceSeconds(promptTokens: prompt.tokens.count)
        let pieces = splitIntoPieces
            ? WhisperClips.split(samples: samples, maxSeconds: maxSeconds)
            : (samples.isEmpty ? [] : [0..<samples.count])
        return Plan(
            prompt: prompt,
            pieces: pieces,
            maxPieceSeconds: maxSeconds,
            recordingSeconds: Double(samples.count) / Double(WhisperClips.sampleRate)
        )
    }

    /// The tokenizer of `kit` as the closure the prompt builder takes: the
    /// special tokens filtered out. The one definition, for the run and for
    /// ``promptTokenCount(kit:terms:)``.
    static func encoder(of kit: WhisperKit) -> ((String) -> [Int])? {
        guard let tokenizer = kit.tokenizer else { return nil }
        return { text in
            tokenizer.encode(text: text).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
    }

    /// How many tokens the prompt of `terms` will have, with the model's own
    /// tokenizer and the builder the run uses (so the figure is the run's, not
    /// an upper bound); `nil` when the model has no tokenizer. The plan of the
    /// time after the stop needs it before the run: the length of a piece and
    /// the estimate both follow it.
    public static func promptTokenCount(kit: WhisperKit, terms: [String]) -> Int? {
        guard let encode = encoder(of: kit) else { return nil }
        return WhisperPromptBuilder.build(terms: terms, encode: encode).tokens.count
    }

    // MARK: - Run

    /// Reads the 16 kHz mono file at `path` (the library converts what it is given).
    public static func loadSamples(path: String) throws -> [Float] {
        try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
    }

    /// Transcribes `samples` (16 kHz mono) with the recipe.
    ///
    /// Runs on the caller's actor: `WhisperKit` is not `Sendable`, and the
    /// app keeps it behind one.
    ///
    /// - Parameter onPlan: called with the plan before the model starts, to log it.
    public static func transcribe(
        kit: WhisperKit,
        samples: [Float],
        language: String?,
        terms: [String],
        splitIntoPieces: Bool = true,
        onPlan: (Plan) -> Void = { _ in },
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Output {
        guard let encode = encoder(of: kit) else { throw Failure.noTokenizer }
        let plan = plan(samples: samples, terms: terms, splitIntoPieces: splitIntoPieces, encode: encode)
        onPlan(plan)
        let options = decodingOptions(language: language, promptTokens: plan.prompt.tokens, pieces: plan.pieces)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let assembled = assemble(results, language: language)
        let timings = Timings(
            windows: Int(results.reduce(0) { $0 + $1.timings.totalDecodingWindows }),
            steps: Int(results.reduce(0) { $0 + $1.timings.totalDecodingLoops }),
            encodingSeconds: results.reduce(0) { $0 + $1.timings.encoding },
            decodingSeconds: results.reduce(0) { $0 + $1.timings.decodingLoop },
            pipelineSeconds: results.reduce(0) { $0 + $1.timings.fullPipeline }
        )
        return Output(text: assembled.text, plan: plan, timings: timings, joined: assembled.joined)
    }

    /// The text of a run. The library decodes all the tokens of the call as one
    /// string, so the start of a piece is a start of sentence in the middle of one.
    /// With `withoutTimestamps` it writes one segment per window, and a window is a
    /// piece (a piece is shorter than 30 s): then the pieces are put together by
    /// ``WhisperClips/join(_:language:)``, which lowercases the capital of a piece
    /// that continues a sentence. When the segments are not one per window (the
    /// model wrote timestamps after all) the library's text is kept, with a capital at the start.
    static func assemble(_ results: [TranscriptionResult], language: String?) -> (text: String, joined: WhisperClips.Joined?) {
        if results.count == 1, let result = results.first,
           result.segments.count > 1,
           result.segments.count == Int(result.timings.totalDecodingWindows) {
            let joined = WhisperClips.join(result.segments.map(\.text), language: language)
            return (joined.text, joined)
        }
        // One window: the library's text, with the capital a sentence starts with
        // (the prompt ends with a comma and the model may go on in lowercase).
        let text = WhisperClips.capitalizingFirstLetter(
            results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return (text, nil)
    }
}

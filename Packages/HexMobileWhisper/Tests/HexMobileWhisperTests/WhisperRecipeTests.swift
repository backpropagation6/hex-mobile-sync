import Foundation
import HexMobileCore
import Testing
import WhisperKit
@testable import HexMobileWhisper

@Suite("Whisper recipe")
struct WhisperRecipeTests {
    private let rate = WhisperClips.sampleRate

    /// One token per character: the prompt size is easy to steer.
    private let encode: (String) -> [Int] = { text in text.unicodeScalars.map { Int($0.value) } }

    @Test("the options: Italian, temperature 0, no timestamps, the prompt as given")
    func options() {
        let options = WhisperRecipe.decodingOptions(language: "it", promptTokens: [11, 22, 33], pieces: [0..<1000])
        #expect(options.language == "it")
        #expect(options.detectLanguage == false)
        #expect(options.temperature == 0)
        #expect(options.withoutTimestamps)
        #expect(options.usePrefillPrompt)
        #expect(options.skipSpecialTokens)
        #expect(options.promptTokens == [11, 22, 33])
        #expect(options.clipTimestamps.isEmpty)
    }

    @Test("no language means detection, no prompt means none")
    func detectionAndEmptyPrompt() {
        let options = WhisperRecipe.decodingOptions(language: nil, promptTokens: [], pieces: [])
        #expect(options.detectLanguage)
        #expect(options.promptTokens == nil)
        #expect(options.clipTimestamps.isEmpty)
    }

    @Test("several pieces become pairs of start and end, joined with no gap")
    func clipTimestamps() {
        let pieces = [0..<188_800, 188_800..<356_800, 356_800..<537_920]
        let options = WhisperRecipe.decodingOptions(language: "it", promptTokens: [], pieces: pieces)
        #expect(options.clipTimestamps.count == 6)
        #expect(options.clipTimestamps[0] == 0)
        #expect(options.clipTimestamps[1] == options.clipTimestamps[2])
        #expect(options.clipTimestamps[3] == options.clipTimestamps[4])
        #expect(abs(options.clipTimestamps[1] - 11.8) < 0.001)
        #expect(abs(options.clipTimestamps[5] - 33.62) < 0.001)
    }

    @Test("a short recording takes the same path as before: no clip timestamps")
    func shortRecording() {
        let samples = [Float](repeating: 0.2, count: 5 * rate)
        let plan = WhisperRecipe.plan(samples: samples, terms: ["Alpha", "Bravo"], encode: encode)
        #expect(plan.pieces == [0..<samples.count])
        let options = WhisperRecipe.decodingOptions(language: "it", promptTokens: plan.prompt.tokens, pieces: plan.pieces)
        #expect(options.clipTimestamps.isEmpty)
    }

    @Test("a long recording is cut for the size of its prompt")
    func longRecording() {
        let samples = [Float](repeating: 0.2, count: 42 * rate)
        // 100 characters of terms: a prompt of about 100 tokens, so pieces of about 15 s.
        let terms = (0..<10).map { "termine\($0)" }
        let plan = WhisperRecipe.plan(samples: samples, terms: terms, encode: encode)
        #expect(plan.prompt.tokens.count > 50)
        #expect(plan.maxPieceSeconds == WhisperClips.maxPieceSeconds(promptTokens: plan.prompt.tokens.count))
        #expect(plan.pieces.count >= 3)
        for piece in plan.pieces { #expect(Double(piece.count) / Double(rate) <= plan.maxPieceSeconds + 0.001) }
        #expect(plan.pieces.first?.lowerBound == 0)
        #expect(plan.pieces.last?.upperBound == samples.count)
        #expect(plan.logLine.hasPrefix("whisper pieces n=\(plan.pieces.count) max="))
    }

    @Test("with no prompt the pieces are the longest allowed")
    func noPrompt() {
        let samples = [Float](repeating: 0.2, count: 42 * rate)
        let plan = WhisperRecipe.plan(samples: samples, terms: [], encode: encode)
        #expect(plan.prompt.tokens.isEmpty)
        #expect(plan.maxPieceSeconds == WhisperClips.maxPieceSeconds(promptTokens: 0))
        #expect(plan.pieces.count == 2)
    }

    @Test("cutting can be turned off, to reproduce the first version in the bench")
    func noSplit() {
        let samples = [Float](repeating: 0.2, count: 42 * rate)
        let plan = WhisperRecipe.plan(samples: samples, terms: ["Alpha"], splitIntoPieces: false, encode: encode)
        #expect(plan.pieces == [0..<samples.count])
        #expect(WhisperRecipe.plan(samples: [], terms: [], splitIntoPieces: false, encode: encode).pieces.isEmpty)
    }

    // MARK: - Text of a run

    private func result(_ segments: [String], windows: Double, text: String? = nil) -> TranscriptionResult {
        var timings = TranscriptionTimings()
        timings.totalDecodingWindows = windows
        return TranscriptionResult(
            text: text ?? segments.joined(),
            segments: segments.enumerated().map { TranscriptionSegment(id: $0.offset, text: $0.element) },
            language: "it",
            timings: timings
        )
    }

    @Test("one segment per window: the pieces are put together and a capital after a comma goes down")
    func piecesJoined() {
        let run = result([" Ho riascoltato le registrazioni,", " Perché mancava una frase.", " Poi ho scritto a Mauro."], windows: 3)
        let assembled = WhisperRecipe.assemble([run], language: "it")
        #expect(assembled.text == "Ho riascoltato le registrazioni, perché mancava una frase. Poi ho scritto a Mauro.")
        #expect(assembled.joined?.logLine == "whisper join pieces=3 lowercased=1")
    }

    @Test("one window is the library's text as it is")
    func oneWindow() {
        let run = result([" Perché no, Mauro."], windows: 1)
        let assembled = WhisperRecipe.assemble([run], language: "it")
        #expect(assembled.text == "Perché no, Mauro.")
        #expect(assembled.joined == nil)
    }

    @Test("a text that opens in lowercase gets its capital, in one window and in pieces")
    func firstCapital() {
        // 2 Nov 2026, s10 with the vocabulary: the prompt ends with a comma.
        let oneWindow = result([" sta andando proprio alla grande, perché comunque il sistema funziona."], windows: 1)
        #expect(WhisperRecipe.assemble([oneWindow], language: "it").text == "Sta andando proprio alla grande, perché comunque il sistema funziona.")
        let pieces = result([" ho riascoltato le registrazioni,", " Perché mancava una frase."], windows: 2)
        #expect(WhisperRecipe.assemble([pieces], language: "it").text == "Ho riascoltato le registrazioni, perché mancava una frase.")
        let timestamps = result([" ciao,", " come stai?", " bene,", " grazie."], windows: 2, text: "ciao, come stai? bene, grazie.")
        #expect(WhisperRecipe.assemble([timestamps], language: "it").text == "Ciao, come stai? bene, grazie.")
    }

    @Test("segments that are not one per window (timestamps written) leave the library's text alone")
    func notOnePerWindow() {
        let run = result([" Ciao,", " Come stai?", " Bene,", " Grazie."], windows: 2, text: "Ciao, Come stai? Bene, Grazie.")
        let assembled = WhisperRecipe.assemble([run], language: "it")
        #expect(assembled.text == "Ciao, Come stai? Bene, Grazie.")
        #expect(assembled.joined == nil)
    }
}

import Foundation
import Testing
@testable import HexMobileCore

@Suite("Whisper prompt")
struct WhisperPromptTests {
    /// One token per character: enough to exercise the cap deterministically.
    private let encode: (String) -> [Int] = { text in text.unicodeScalars.map { Int($0.value) } }

    @Test("terms are joined with commas after a leading space, as the Mac bench did")
    func shape() {
        let prompt = WhisperPromptBuilder.build(terms: ["Vercel", "Hugging Face"], encode: encode)
        #expect(String(String.UnicodeScalarView(prompt.tokens.compactMap(Unicode.Scalar.init))) == " Vercel, Hugging Face")
        #expect(prompt.termsUsed == 2)
        #expect(prompt.termsOffered == 2)
        #expect(prompt.logLine == "whisper prompt terms=2/2 tokens=\(prompt.tokens.count)")
    }

    @Test("duplicates ignoring case and empty terms are dropped")
    func distinct() {
        let prompt = WhisperPromptBuilder.build(terms: ["Hex", " ", "hex", "", "Zentrix", "HEX "], encode: encode)
        #expect(prompt.termsOffered == 2)
        #expect(prompt.termsUsed == 2)
    }

    @Test("the cap holds and a term that does not fit is left out whole")
    func cap() {
        // " " + "Alpha" = 6 tokens; adding ", Bravo" makes 13; a cap of 12 leaves Bravo out.
        let prompt = WhisperPromptBuilder.build(terms: ["Alpha", "Bravo", "Cy"], cap: 12, encode: encode)
        #expect(prompt.tokens.count <= 12)
        // "Bravo" is skipped, the shorter "Cy" after it still fits: " Alpha, Cy" = 11.
        #expect(prompt.termsUsed == 2)
        #expect(String(String.UnicodeScalarView(prompt.tokens.compactMap(Unicode.Scalar.init))) == " Alpha, Cy")
        #expect(prompt.termsOffered == 3)
    }

    @Test("the default cap stays under what WhisperKit keeps (111)")
    func defaultCap() {
        #expect(WhisperPromptBuilder.tokenCap < 111)
        let many = (0..<200).map { "termine\($0)" }
        let prompt = WhisperPromptBuilder.build(terms: many, encode: encode)
        #expect(prompt.tokens.count <= WhisperPromptBuilder.tokenCap)
        #expect(prompt.termsUsed < prompt.termsOffered)
        #expect(prompt.termsUsed > 0)
    }

    @Test("no terms, no prompt")
    func empty() {
        let prompt = WhisperPromptBuilder.build(terms: [], encode: encode)
        #expect(prompt.tokens.isEmpty)
        #expect(prompt.termsUsed == 0)
        #expect(prompt.termsOffered == 0)
    }
}

@Suite("Whisper locator")
struct WhisperLocatorTests {
    private let model = "openai_whisper-large-v3-v20240930_turbo_632MB"

    private func make(_ directories: [String], in root: URL) throws {
        for directory in directories {
            try FileManager.default.createDirectory(
                at: root.appending(path: directory, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
    }

    private func touch(_ files: [String], in root: URL) throws {
        for file in files {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url)
        }
    }

    private func modelDirectories(_ name: String) -> [String] {
        WhisperLocator.requiredModels.map { "\(name)/\($0)" }
    }

    private let tokenizerFiles = [
        "tokenizers/models/openai/whisper-large-v3/tokenizer.json",
        "tokenizers/models/openai/whisper-large-v3/tokenizer_config.json",
    ]

    @Test("no folder")
    func noFolder() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        #expect(WhisperLocator.locate(root: temp.url.appending(path: "whisper")) == .missing(.noFolder))
    }

    @Test("an empty folder holds no model")
    func noModel() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        #expect(WhisperLocator.locate(root: temp.url) == .missing(.noModel))
    }

    @Test("the model and the tokenizer in place are found")
    func ready() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        try make(modelDirectories(model), in: temp.url)
        try touch(tokenizerFiles, in: temp.url)
        let availability = WhisperLocator.locate(root: temp.url)
        let installation = try #require(availability.installation)
        #expect(installation.modelName == model)
        #expect(installation.tokenizerFolder.path.hasSuffix("tokenizers/models/openai/whisper-large-v3"))
    }

    @Test("a model in a subfolder of a subfolder is found too, three levels down is not")
    func nested() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        try make(modelDirectories("extra/\(model)"), in: temp.url)
        try touch(tokenizerFiles, in: temp.url)
        #expect(WhisperLocator.locate(root: temp.url).installation?.modelName == model)

        let tooDeep = try TemporaryDirectory()
        defer { tooDeep.cleanup() }
        try make(modelDirectories("a/b/\(model)"), in: tooDeep.url)
        try touch(tokenizerFiles, in: tooDeep.url)
        #expect(WhisperLocator.locate(root: tooDeep.url) == .missing(.noModel))
    }

    @Test("the tokenizer is found wherever a folder copy put it, up to five levels down")
    func tokenizerNested() throws {
        // `devicectl` may put a copied folder inside the destination, not as it.
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        try make(modelDirectories(model), in: temp.url)
        try touch(tokenizerFiles.map { $0.replacingOccurrences(of: "whisper-large-v3/", with: "whisper-large-v3/whisper-large-v3/") }, in: temp.url)
        let found = WhisperLocator.locate(root: temp.url).installation
        #expect(found?.tokenizerFolder.path.hasSuffix("openai/whisper-large-v3/whisper-large-v3") == true)

        let flat = try TemporaryDirectory()
        defer { flat.cleanup() }
        try make(modelDirectories(model), in: flat.url)
        try touch(["whisper-large-v3/tokenizer.json", "whisper-large-v3/tokenizer_config.json"], in: flat.url)
        #expect(WhisperLocator.locate(root: flat.url).installation?.tokenizerFolder.lastPathComponent == "whisper-large-v3")

        // Tokenizer files in a folder of another name are not taken: it could be another model's.
        let other = try TemporaryDirectory()
        defer { other.cleanup() }
        try make(modelDirectories(model), in: other.url)
        try touch(["whisper-small/tokenizer.json", "whisper-small/tokenizer_config.json"], in: other.url)
        #expect(WhisperLocator.locate(root: other.url) == .missing(.noTokenizer(missing: ["tokenizer.json", "tokenizer_config.json"])))
    }

    @Test("a model with a Core ML model missing is incomplete")
    func incomplete() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        try make(["\(model)/MelSpectrogram.mlmodelc", "\(model)/AudioEncoder.mlmodelc"], in: temp.url)
        try touch(tokenizerFiles, in: temp.url)
        #expect(WhisperLocator.locate(root: temp.url) == .missing(.incompleteModel(name: model, missing: ["TextDecoder.mlmodelc"])))
    }

    @Test("without the tokenizer the model is not usable: the library would download it")
    func noTokenizer() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        try make(modelDirectories(model), in: temp.url)
        #expect(WhisperLocator.locate(root: temp.url) == .missing(.noTokenizer(missing: ["tokenizer.json", "tokenizer_config.json"])))

        try touch(["tokenizers/models/openai/whisper-large-v3/tokenizer.json"], in: temp.url)
        #expect(WhisperLocator.locate(root: temp.url) == .missing(.noTokenizer(missing: ["tokenizer_config.json"])))
    }

    @Test("a model outside the large-v3 family is refused: its tokenizer is another one")
    func unsupported() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        try make(modelDirectories("openai_whisper-small_216MB"), in: temp.url)
        try touch(tokenizerFiles, in: temp.url)
        #expect(WhisperLocator.locate(root: temp.url) == .missing(.unsupportedModel(name: "openai_whisper-small_216MB")))

        // With a supported one beside it, that one is chosen.
        try make(modelDirectories(model), in: temp.url)
        #expect(WhisperLocator.locate(root: temp.url).installation?.modelName == model)
    }

    @Test("log values are stable")
    func logValues() {
        #expect(WhisperMissing.noFolder.logValue == "no-folder")
        #expect(WhisperMissing.noModel.logValue == "no-model")
        #expect(WhisperMissing.incompleteModel(name: "m", missing: ["a", "b"]).logValue == "incomplete-model:m:a+b")
        #expect(WhisperMissing.noTokenizer(missing: ["tokenizer.json"]).logValue == "no-tokenizer:tokenizer.json")
    }
}

@Suite("Whisper deadline")
struct WhisperPolicyTests {
    @Test("the estimate counts pieces and decoder steps: fixed + piece x n + step x steps, times the margin")
    func estimate() {
        // One piece, a 100-token prompt, 4.8 s: steps = 105 + 6 x 4.8.
        let steps = 105.0 + 6.0 * 4.8
        let expected = 1.15 * (0.1 + 0.4 + 0.015 * steps)
        #expect(abs(FinalPassPolicy.whisperEstimate(forRecordingSeconds: 4.8, promptTokens: 100) - expected) < 1e-9)
        // Nothing to read still pays one piece and the prompt.
        #expect(abs(FinalPassPolicy.whisperEstimate(forRecordingSeconds: 0, promptTokens: 100) - 1.15 * (0.5 + 0.015 * 105)) < 1e-9)
        #expect(FinalPassPolicy.whisperEstimate(forRecordingSeconds: -3, promptTokens: 100) == FinalPassPolicy.whisperEstimate(forRecordingSeconds: 0, promptTokens: 100))
        // The default is the longest prompt there can be.
        #expect(FinalPassPolicy.whisperEstimate(forRecordingSeconds: 4.8) == FinalPassPolicy.whisperEstimate(forRecordingSeconds: 4.8, promptTokens: 100))
    }

    @Test("against the phone runs it was fitted on: never below the measure, within a half above it")
    func againstPhone() {
        // 2 Nov 2026, iPhone 16 Pro, one window: 5.7 s with no prompt took 0.88 s,
        // 4.8 s with a 100-token prompt took 2.34 s.
        let noPrompt = FinalPassPolicy.whisperEstimate(forRecordingSeconds: 5.7, promptTokens: 0)
        #expect(noPrompt >= 0.88 && noPrompt <= 0.88 * 1.5)
        let withPrompt = FinalPassPolicy.whisperEstimate(forRecordingSeconds: 4.8, promptTokens: 100)
        #expect(withPrompt >= 2.34 && withPrompt <= 2.34 * 1.5)
    }

    @Test("a prompt costs a decoder pass per piece, and a longer recording more pieces")
    func growth() {
        let short = FinalPassPolicy.whisperEstimate(forRecordingSeconds: 10, promptTokens: 100)
        let noPrompt = FinalPassPolicy.whisperEstimate(forRecordingSeconds: 10, promptTokens: 0)
        // 100 prompt tokens at 15 ms, with the margin: about 1.7 s.
        #expect(abs((short - noPrompt) - 1.15 * 0.015 * 101) < 1e-9)
        // 24 s needs 2 pieces with the prompt, 1 without: the prompt is paid twice.
        let long = FinalPassPolicy.whisperEstimate(forRecordingSeconds: 24, promptTokens: 100)
        let longNoPrompt = FinalPassPolicy.whisperEstimate(forRecordingSeconds: 24, promptTokens: 0)
        #expect(long - longNoPrompt > 2 * (short - noPrompt) - 0.5)
    }

    @Test("the plan with the prompt's real tokens: 15.0 s with 98 is one piece, with the cap of 100 it is two and Whisper is skipped")
    func realPromptTokens() {
        // The run cuts with the real count (WhisperRecipe.plan); a plan that used the cap
        // would call two pieces what the run reads as one.
        #expect(WhisperClips.plannedPieces(recordingSeconds: 15.0, promptTokens: 98) == 1)
        #expect(WhisperClips.plannedPieces(recordingSeconds: 15.0, promptTokens: 100) == 2)
        let real = FinalPassPolicy.whisperEstimate(forRecordingSeconds: 15.0, promptTokens: 98)
        let cap = FinalPassPolicy.whisperEstimate(forRecordingSeconds: 15.0, promptTokens: 100)
        #expect(real < 5 && cap > 6)
        if case .run = FinalPassPolicy.whisperPlan(recordingSeconds: 15.0, elapsedSinceStop: 0.8, promptTokens: 98, cleanupCharacters: 270) {} else {
            Issue.record("15 s with a 98-token prompt is one piece and fits")
        }
        if case .skip = FinalPassPolicy.whisperPlan(recordingSeconds: 15.0, elapsedSinceStop: 0.8, promptTokens: 100, cleanupCharacters: 270) {} else {
            Issue.record("the same with the cap is planned as two pieces and does not")
        }
    }

    @Test("with a cleanup to come, Whisper gets what is left after the stop and the cleanup's reserve")
    func plan() {
        // 5 s, 100 terms' prompt, 90 characters of text: reserve = max(1, 1.3 x 0.6) + 0.4 + 0.45 = 1.85 s.
        let reserve = FinalPassPolicy.cleanupReserve(characters: 90)
        #expect(abs(reserve - 1.85) < 1e-9)
        // Whisper gives up at 8 - 1.85 = 6.15 s after the stop: an absolute time.
        #expect(FinalPassPolicy.whisperPlan(recordingSeconds: 5, elapsedSinceStop: 1, cleanupCharacters: 90) == .run(endBy: 8 - reserve))
        #expect(FinalPassPolicy.whisperDeadline(endBy: 8 - reserve, elapsedSinceStop: 1) == 8 - reserve - 1)
        // No cleanup follows: the reserve is nothing.
        #expect(FinalPassPolicy.whisperPlan(recordingSeconds: 5, elapsedSinceStop: 1, cleanupCharacters: nil) == .run(endBy: 8))
    }

    @Test("a long text keeps more time for its cleanup, and Whisper is not started when both do not fit")
    func longText() {
        // 760 characters: reserve 1.3 x (0.25 + 0.0039 x 760) + 0.4 + 0.45 = 5.0 s.
        #expect(abs(FinalPassPolicy.cleanupReserve(characters: 760) - (1.3 * (0.25 + 0.0039 * 760) + 0.4 + 0.45)) < 1e-9)
        // A 14 s dictation, Apple done in 0.7 s, 230 characters: it fits.
        if case .run = FinalPassPolicy.whisperPlan(recordingSeconds: 14, elapsedSinceStop: 0.7, cleanupCharacters: 230) {} else {
            Issue.record("a 14 s dictation should fit")
        }
        // A 42 s dictation (760 characters): 4 pieces cost about 14 s, nothing is left for it.
        let plan = FinalPassPolicy.whisperPlan(recordingSeconds: 42.4, elapsedSinceStop: 0.7, cleanupCharacters: 760)
        guard case let .skip(estimate, available) = plan else {
            Issue.record("a 42 s dictation should not start Whisper")
            return
        }
        #expect(estimate > 10)
        #expect(abs(available - (8 - 0.7 - FinalPassPolicy.cleanupReserve(characters: 760))) < 1e-9)
    }

    @Test("an estimate that does not fit is not started")
    func skip() {
        let estimate = FinalPassPolicy.whisperEstimate(forRecordingSeconds: 10)
        // A 90-character cleanup reserves 1.85 s: Whisper may use 6.15 s minus the time since the stop.
        let endBy = 8 - FinalPassPolicy.cleanupReserve(characters: 90)
        let early = endBy - estimate - 0.01
        #expect(FinalPassPolicy.whisperPlan(recordingSeconds: 10, elapsedSinceStop: early, cleanupCharacters: 90) == .run(endBy: endBy))
        let late = endBy - estimate + 0.5
        #expect(FinalPassPolicy.whisperPlan(recordingSeconds: 10, elapsedSinceStop: late, cleanupCharacters: 90)
            == .skip(estimate: estimate, available: endBy - late))
        // Apple used the whole budget.
        #expect(FinalPassPolicy.whisperPlan(recordingSeconds: 1, elapsedSinceStop: 8, cleanupCharacters: 90)
            == .skip(estimate: FinalPassPolicy.whisperEstimate(forRecordingSeconds: 1), available: 0))
        #expect(FinalPassPolicy.whisperPlan(recordingSeconds: 1, elapsedSinceStop: 9, cleanupCharacters: nil)
            == .skip(estimate: FinalPassPolicy.whisperEstimate(forRecordingSeconds: 1), available: 0))
    }

    @Test("the deadline never takes the cleanup's reserve out of the budget")
    func keepsCleanupTime() {
        for characters in [0, 90, 230, 760, 1500] {
            for elapsed in stride(from: 0.0, through: 8.0, by: 0.25) {
                if case let .run(endBy) = FinalPassPolicy.whisperPlan(recordingSeconds: 0, elapsedSinceStop: elapsed, cleanupCharacters: characters) {
                    let deadline = FinalPassPolicy.whisperDeadline(endBy: endBy, elapsedSinceStop: elapsed)
                    #expect(elapsed + deadline + FinalPassPolicy.cleanupReserve(characters: characters) <= FinalPassPolicy.totalBudget + 1e-9)
                }
            }
        }
    }

    @Test("a wait between the decision and the run does not eat the cleanup's reserve")
    func waitBeforeRun() {
        // The controller awaits the Live Activity after deciding and before FinalPass.run.
        // The first version gave Whisper `available` measured before the wait: when it ran to its
        // deadline the cleanup was left with `reserve - wait`, and with a short text the reserve
        // was the 1 s the cleanup needs to start.
        let minimum = FinalPassPolicy.minimumCleanupTime + FinalPassPolicy.whisperContentionMargin
        var checked = 0
        var oldWayFailed = 0
        for characters in [0, 40, 90, 230, 760] {
            for elapsed in [0.5, 1.0, 2.0] {
                for wait in [0.0, 0.1, 0.3, 0.5, 1.0] {
                    guard case let .run(firstEnd) = FinalPassPolicy.whisperPlan(recordingSeconds: 3, elapsedSinceStop: elapsed, cleanupCharacters: characters)
                    else { continue }
                    // Decided again with the clock after the wait.
                    let later = elapsed + wait
                    guard case let .run(endBy) = FinalPassPolicy.whisperPlan(recordingSeconds: 3, elapsedSinceStop: later, cleanupCharacters: characters)
                    else { continue }
                    let deadline = FinalPassPolicy.whisperDeadline(endBy: endBy, elapsedSinceStop: later)
                    // Whisper runs to the deadline: what the cleanup finds when it starts.
                    guard case let .run(cleanup) = FinalPassPolicy.cleanupPlan(elapsedSinceStop: later + deadline, characters: characters) else {
                        Issue.record("the cleanup must start: chars \(characters) elapsed \(elapsed) wait \(wait)")
                        continue
                    }
                    #expect(cleanup >= minimum - 1e-9, "chars \(characters) elapsed \(elapsed) wait \(wait)")
                    #expect(cleanup >= FinalPassPolicy.minimumCleanupTime)
                    checked += 1
                    // The old way: the deadline measured before the wait.
                    let oldDeadline = FinalPassPolicy.whisperDeadline(endBy: firstEnd, elapsedSinceStop: elapsed)
                    if case .skip = FinalPassPolicy.cleanupPlan(elapsedSinceStop: later + oldDeadline, characters: characters) { oldWayFailed += 1 }
                }
            }
        }
        #expect(checked > 30)
        // The case was real: with the old deadline the cleanup was skipped for some of them.
        #expect(oldWayFailed > 0)
    }

    @Test("a wait that eats the room turns the plan into a skip")
    func waitEatsRoom() {
        let estimate = FinalPassPolicy.whisperEstimate(forRecordingSeconds: 10)
        let endBy = 8 - FinalPassPolicy.cleanupReserve(characters: 90)
        let decided = endBy - estimate - 0.05
        guard case .run = FinalPassPolicy.whisperPlan(recordingSeconds: 10, elapsedSinceStop: decided, cleanupCharacters: 90) else {
            Issue.record("it fits when decided")
            return
        }
        // 0.2 s of Live Activity later, it does not.
        guard case .skip = FinalPassPolicy.whisperPlan(recordingSeconds: 10, elapsedSinceStop: decided + 0.2, cleanupCharacters: 90) else {
            Issue.record("it must not start once the wait took its room")
            return
        }
    }
}

@Suite("Cleanup time")
struct CleanupTimePolicyTests {
    @Test("the estimate is a line through the phone's measures: 87 characters 0.6 s, 760 characters 3.2 s")
    func estimate() {
        #expect(abs(FinalPassPolicy.cleanupEstimate(characters: 87) - 0.589) < 0.01)
        #expect(abs(FinalPassPolicy.cleanupEstimate(characters: 760) - 3.214) < 0.01)
        #expect(FinalPassPolicy.cleanupEstimate(characters: -4) == 0.25)
    }

    @Test("whatever Whisper's deadline, the cleanup that follows it starts")
    func cleanupStartsAfterWhisper() {
        var checked = 0
        for characters in stride(from: 0, through: 1800, by: 30) {
            for elapsed in stride(from: 0.3, through: 6.0, by: 0.1) {
                for recording in [1.0, 5.0, 14.0] {
                    guard case let .run(endBy) = FinalPassPolicy.whisperPlan(recordingSeconds: recording, elapsedSinceStop: elapsed, cleanupCharacters: characters)
                    else { continue }
                    // Whisper runs to its deadline; the cleanup is asked then.
                    let plan = FinalPassPolicy.cleanupPlan(elapsedSinceStop: endBy, characters: characters)
                    guard case let .run(timeout) = plan else {
                        Issue.record("chars \(characters) elapsed \(elapsed) recording \(recording): \(plan)")
                        continue
                    }
                    #expect(timeout >= FinalPassPolicy.minimumCleanupTime + FinalPassPolicy.whisperContentionMargin - 1e-9)
                    checked += 1
                }
            }
        }
        #expect(checked > 100)
    }

    @Test("the reserve is the estimate with its margin, at least the shortest cleanup, plus the contention and the end-to-end margins")
    func reserve() {
        let floor = FinalPassPolicy.minimumCleanupTime + FinalPassPolicy.whisperContentionMargin + FinalPassPolicy.endToEndMargin
        #expect(FinalPassPolicy.cleanupReserve(characters: 0) == floor)
        #expect(FinalPassPolicy.cleanupReserve(characters: 100) == floor)
        #expect(abs(FinalPassPolicy.cleanupReserve(characters: 760) - (4.18 + FinalPassPolicy.whisperContentionMargin + FinalPassPolicy.endToEndMargin)) < 0.05)
        #expect(FinalPassPolicy.whisperContentionMargin >= 0.3 && FinalPassPolicy.whisperContentionMargin <= 0.5)
    }
}

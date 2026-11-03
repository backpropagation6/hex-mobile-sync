import CoreML
import Foundation
import HexMobileCore
import HexMobileSpeech
import HexMobileWhisper
import Synchronization
import WhisperKit

/// Why the Whisper engine could not give a text.
enum WhisperEngineError: Error, Equatable, CustomStringConvertible {
    /// The model is not in memory (not installed, still loading, or released).
    case notLoaded
    /// A previous run is still finishing (a deadline returns control before
    /// the model stops working).
    case busy
    /// The model loaded but has no tokenizer.
    case noTokenizer

    var description: String {
        switch self {
        case .notLoaded: "not-loaded"
        case .busy: "busy"
        case .noTokenizer: "no-tokenizer"
        }
    }
}

/// What a load took, for the log line `whisper load dt= units= footprint=`.
struct WhisperLoadReport: Sendable, Equatable {
    var seconds: Double
    var units: String
    /// The encoder and decoder were asked for the Neural Engine (not the CPU-only
    /// load that follows a Core ML error): only such a load compiles the model for it.
    var neuralEngine: Bool
    var footprintMB: String
    /// The most memory the process has used so far, the load included.
    var peakMB: String

    var logLine: String {
        "whisper load dt=\(String(format: "%.2f", seconds)) units=\(units) footprint=\(footprintMB)MB peak=\(peakMB)MB"
    }
}

enum WhisperLoadOutcome: Sendable, Equatable {
    case loaded(WhisperLoadReport)
    case alreadyLoaded
    case failed(String)
}

/// Owns the loaded WhisperKit behind an actor.
///
/// `WhisperKit` is a class that is not `Sendable`; every use of it happens
/// here, one at a time. The state is readable from anywhere without waiting
/// for the actor, because a model load keeps the actor busy and the stop of a
/// dictation must be able to ask "is it ready?" and move on with the Apple
/// text when it is not.
actor WhisperModelHolder {
    enum State: Sendable, Equatable {
        case unloaded
        case loading
        case ready
        case failed(String)
    }

    private let stateBox = Mutex<State>(.unloaded)
    private let log: @Sendable (String) -> Void

    private var kit: WhisperKit?
    private var loadTask: Task<WhisperLoadOutcome, Never>?
    /// A run is in progress. WhisperKit checks for cancellation between
    /// decoder steps, but a Core ML prediction cannot be interrupted: after a
    /// deadline the run may go on for a moment, and a second one must not
    /// start on top of it.
    private var isRunning = false
    /// The session ended while a load or a run was in progress: release the
    /// model as soon as it is idle.
    private var unloadWhenIdle = false
    /// Set after a run failed on the Neural Engine: the next load uses the CPU only.
    private var cpuOnly = false

    nonisolated var state: State { stateBox.withLock { $0 } }
    nonisolated var isReady: Bool { state == .ready }

    /// - Parameter log: where the holder writes its own log lines (load,
    ///   prompt, compute fallback); the app passes `Diagnostics.record`.
    init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    // MARK: - Load

    /// Loads the model (once; a second call joins the first). Never throws
    /// and never touches the network: the tokenizer is read from
    /// `installation` first, and only then handed to the library (see
    /// ``WhisperLocator``).
    func load(_ installation: WhisperInstallation) async -> WhisperLoadOutcome {
        if kit != nil { return .alreadyLoaded }
        if let loadTask { return await loadTask.value }
        unloadWhenIdle = false
        setState(.loading)
        let task = Task { await self.performLoad(installation) }
        loadTask = task
        let outcome = await task.value
        loadTask = nil
        if unloadWhenIdle { await unloadNow() }
        return outcome
    }

    private func performLoad(_ installation: WhisperInstallation) async -> WhisperLoadOutcome {
        let started = ContinuousClock.now
        do {
            // WhisperKit downloads the tokenizer from the Hugging Face Hub when
            // it cannot load one from disk. Load it here first, from the same
            // folder and with the same arguments: if this succeeds, the
            // library's own attempt finds the same files and never gets to the
            // download.
            // (WhisperKit looks at the top level of `tokenizerFolder` for a
            // `tokenizer.json`, so the folder is given as it was found.)
            let hub = HubApiWrapper(downloadBase: installation.tokenizerFolder)
            _ = try await AutoTokenizerWrapper.from(modelFolder: installation.tokenizerFolder, hubApi: hub)

            let compute = ModelComputeOptions(
                // The mel spectrogram is cheap, and the default (the GPU) is
                // not allowed to an app in the background (the Action Button).
                melCompute: .cpuOnly,
                audioEncoderCompute: cpuOnly ? .cpuOnly : .cpuAndNeuralEngine,
                textDecoderCompute: cpuOnly ? .cpuOnly : .cpuAndNeuralEngine
            )
            let config = WhisperKitConfig(
                modelFolder: installation.modelFolder.path,
                tokenizerFolder: installation.tokenizerFolder,
                computeOptions: compute,
                verbose: false,
                logLevel: .none,
                prewarm: false,
                load: true,
                download: false
            )
            let loaded = try await WhisperKit(config)
            guard loaded.tokenizer != nil else { throw WhisperEngineError.noTokenizer }
            kit = loaded
            setState(.ready)
            let report = WhisperLoadReport(
                seconds: Self.seconds(since: started),
                units: Self.describe(compute),
                neuralEngine: !cpuOnly,
                footprintMB: Diagnostics.footprintMB,
                peakMB: Diagnostics.peakFootprintMB
            )
            log(report.logLine)
            return .loaded(report)
        } catch {
            let reason = Self.reason(error)
            setState(.failed(reason))
            log("whisper load failed dt=\(String(format: "%.2f", Self.seconds(since: started))) reason=\(reason)")
            return .failed(reason)
        }
    }

    // MARK: - Unload

    /// Releases the model, now or as soon as the current load or run ends.
    func unload() async {
        if loadTask != nil || isRunning {
            unloadWhenIdle = true
            return
        }
        await unloadNow()
    }

    private func unloadNow() async {
        unloadWhenIdle = false
        guard let loaded = kit else {
            if loadTask == nil { setState(.unloaded) }
            return
        }
        kit = nil
        await loaded.unloadModels()
        setState(.unloaded)
        log("whisper unloaded footprint=\(Diagnostics.footprintMB)MB")
        // Core ML gives memory back late, if at all: the figure right after
        // the unload says little. `state` tells whether another load began in
        // the ten seconds (the number then includes it).
        let log = self.log
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            let state = self.map { "\($0.state)" } ?? "gone"
            log("whisper unloaded +10s footprint=\(Diagnostics.footprintMB)MB peak=\(Diagnostics.peakFootprintMB)MB state=\(state)")
        }
    }

    // MARK: - Prompt

    /// The tokens the prompt of `terms` will have in the next run, or `nil` with no
    /// model in memory or no tokenizer. Cheap (the terms are encoded, nothing is
    /// run); the caller bounds the wait, because a call that arrives while the
    /// actor is busy with something synchronous waits for it.
    func promptTokenCount(terms: [String]) -> Int? {
        guard let kit else { return nil }
        return WhisperRecipe.promptTokenCount(kit: kit, terms: terms)
    }

    // MARK: - Transcribe

    /// Reads `fileURL` and returns its text.
    ///
    /// The options and the cut of a long recording into pieces are
    /// ``WhisperRecipe``'s, shared with `tools/whisper-bench`: temperature 0
    /// with the library's usual fallbacks (the deadline of the caller bounds
    /// the time), no timestamps, the language of the locale, the vocabulary
    /// terms as a prompt, and a recording longer than the decoder can read in
    /// one window cut at the speaker's pauses (otherwise WhisperKit drops the
    /// end of the window when the prompt and the text fill its 224 tokens).
    func transcribe(fileURL: URL, language: String?, terms: [String]) async throws -> String {
        guard let kit else { throw WhisperEngineError.notLoaded }
        guard !isRunning else { throw WhisperEngineError.busy }
        guard kit.tokenizer != nil else { throw WhisperEngineError.noTokenizer }

        isRunning = true
        let log = self.log
        let outcome: Result<WhisperRecipe.Output, any Error>
        do {
            let samples = try WhisperRecipe.loadSamples(path: fileURL.path)
            outcome = .success(try await WhisperRecipe.transcribe(
                kit: kit,
                samples: samples,
                language: language,
                terms: terms,
                onPlan: { plan in
                    log(plan.prompt.logLine)
                    log(plan.logLine)
                }
            ))
        } catch {
            outcome = .failure(error)
        }
        isRunning = false
        if case let .success(output) = outcome {
            log(output.timings.logLine)
            if let joined = output.joined { log(joined.logLine) }
        }
        log("whisper run footprint=\(Diagnostics.footprintMB)MB peak=\(Diagnostics.peakFootprintMB)MB")

        if case let .failure(error) = outcome, Self.isCoreMLError(error), !cpuOnly, !WhisperKit.isRunningOnSimulator {
            // The Neural Engine may be refused in the background. The next load
            // uses the CPU only; this dictation keeps the Apple text.
            cpuOnly = true
            unloadWhenIdle = true
            log("whisper compute fallback next=cpuOnly after=\(Self.reason(error))")
        }
        if unloadWhenIdle { await unloadNow() }

        return try outcome.get().text
    }

    // MARK: - Helpers

    private func setState(_ new: State) {
        stateBox.withLock { $0 = new }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// `mel:cpuOnly/enc:cpuAndNeuralEngine/dec:cpuAndNeuralEngine`; on the
    /// simulator the library forces the CPU for all three.
    static func describe(_ options: ModelComputeOptions) -> String {
        func name(_ units: MLComputeUnits) -> String {
            switch units {
            case .cpuOnly: "cpuOnly"
            case .cpuAndGPU: "cpuAndGPU"
            case .cpuAndNeuralEngine: "cpuAndNeuralEngine"
            case .all: "all"
            @unknown default: "unknown"
            }
        }
        return "mel:\(name(options.melCompute))/enc:\(name(options.audioEncoderCompute))/dec:\(name(options.textDecoderCompute))"
    }

    /// A failure of Core ML itself (not a cancellation, not a bad audio file).
    static func isCoreMLError(_ error: any Error) -> Bool {
        (error as NSError).domain == MLModelErrorDomain
    }

    static func reason(_ error: any Error) -> String {
        if let error = error as? WhisperEngineError { return error.description }
        if error is CancellationError { return "cancelled" }
        let nsError = error as NSError
        return "\(nsError.domain)/\(nsError.code)"
    }
}

/// `FinalPassEngine` over WhisperKit: the second opinion after the Apple
/// pass. The model is loaded elsewhere, ahead of the stop (see
/// ``WhisperModelHolder``); with no model in memory this throws `notLoaded`
/// right away and the caller keeps the Apple text.
struct WhisperFinalPassEngine: FinalPassEngine {
    let holder: WhisperModelHolder

    var name: String { "whisper" }

    func transcribe(fileURL: URL, locale: Locale, contextualStrings: [String]) async throws -> String {
        try await holder.transcribe(
            fileURL: fileURL,
            language: locale.language.languageCode?.identifier,
            terms: contextualStrings
        )
    }
}

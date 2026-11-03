import Foundation
import HexMobileCore
import Observation
import UIKit

/// What the app knows about the Whisper engine: whether the model is on the
/// iPhone, whether it is in memory, and the calls that load and release it.
///
/// Nothing here starts a load by itself: the dictation controller asks for
/// one when a session opens (``beginLoading(reason:)``) and releases it when
/// the session ends, and Settings can prepare it by hand
/// (``prepare()``).
@MainActor
@Observable
final class WhisperModel {
    enum LoadState: Equatable {
        /// Not in memory.
        case idle
        case loading
        /// In memory; how long the load took, in seconds.
        case ready(seconds: Double)
        case failed(String)
    }

    /// What is installed under `Library/Application Support/whisper`; re-read
    /// by ``refreshAvailability()``.
    private(set) var availability: WhisperAvailability
    private(set) var loadState: LoadState = .idle
    /// `<model folder>|<iOS version>` of the last load on the Neural Engine that succeeded
    /// (not a CPU-only load after a Core ML error): Core ML
    /// compiles the model for the Neural Engine at the first load and again
    /// after an iOS update (the first load on the phone took 747 s on
    /// 2 Nov 2026, the later ones 3 to 4 s). Settings says so while the
    /// installed model has no such record.
    private(set) var preparedFor: String?
    private static let preparedKey = "whisper.preparedFor"

    @ObservationIgnored let holder: WhisperModelHolder
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var memoryObserver: (any NSObjectProtocol)?

    init() {
        holder = WhisperModelHolder(log: { line in
            Task { @MainActor in Diagnostics.record(line) }
        })
        availability = AppPaths.whisperAvailability()
        preparedFor = UserDefaults.standard.string(forKey: Self.preparedKey)
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.memoryWarning() }
        }
    }

    /// The model and the tokenizer are on the iPhone.
    var isInstalled: Bool { availability.installation != nil }

    private static func preparedTag(for installation: WhisperInstallation) -> String {
        "\(installation.modelName)|\(UIDevice.current.systemVersion)"
    }

    /// The installed model has loaded on this iOS version before, so the next
    /// load does not compile it again (as far as the app can tell: Core ML may
    /// drop its cache on its own).
    var isPrepared: Bool {
        guard let installation = availability.installation else { return false }
        return preparedFor == Self.preparedTag(for: installation)
    }

    /// In memory, so a dictation can use it right now. Readable without
    /// waiting for a load that is in progress.
    nonisolated var isReady: Bool { holder.isReady }

    /// Looks at the folder again (after a copy from the Mac).
    func refreshAvailability() {
        availability = AppPaths.whisperAvailability()
    }

    /// A copy made while the app runs shows up at the next load or visit to
    /// Settings; this only looks again when nothing was found.
    private func refreshAvailabilityIfMissing() {
        if !isInstalled { refreshAvailability() }
    }

    /// Loads the model in the background and returns at once. A load already
    /// running or done is left alone; nothing happens when the model is not
    /// installed.
    func beginLoading(reason: String) {
        refreshAvailabilityIfMissing()
        guard let installation = availability.installation else { return }
        guard loadTask == nil, !holder.isReady else { return }
        Diagnostics.record("whisper load begin reason=\(reason) model=\(installation.modelName) \(Diagnostics.processSummary())")
        loadState = .loading
        loadTask = Task { [holder] in
            let outcome = await holder.load(installation)
            self.finishLoading(outcome)
        }
    }

    /// Loads the model and waits for it.
    func loadAndWait(reason: String) async {
        beginLoading(reason: reason)
        await loadTask?.value
    }

    /// Releases the model now, or as soon as a run in progress ends.
    func release(reason: String) async {
        guard loadState != .idle || holder.state != .unloaded else { return }
        Diagnostics.record("whisper release reason=\(reason) \(Diagnostics.processSummary())")
        await holder.unload()
        if loadTask == nil { loadState = .idle }
    }

    /// Settings > Prepare: loads the model (the first load makes Core ML
    /// compile it for the Neural Engine, which can take minutes, and that work
    /// is kept) and releases it unless a dictation needs it.
    func prepare(keepLoaded: Bool) async {
        await loadAndWait(reason: "prepare")
        if !keepLoaded { await release(reason: "prepared") }
    }

    private func finishLoading(_ outcome: WhisperLoadOutcome) {
        loadTask = nil
        switch outcome {
        case let .loaded(report):
            loadState = .ready(seconds: report.seconds)
            // Only a load that asked for the Neural Engine compiled the model for it:
            // the CPU-only load after a Core ML error says nothing about that
            // (the simulator asks for it too, as before).
            if report.neuralEngine, let installation = availability.installation {
                let tag = Self.preparedTag(for: installation)
                preparedFor = tag
                UserDefaults.standard.set(tag, forKey: Self.preparedKey)
            }
        case .alreadyLoaded: if case .ready = loadState {} else { loadState = .ready(seconds: 0) }
        case let .failed(reason): loadState = .failed(reason)
        }
        // A release that arrived during the load took effect inside the holder.
        if !holder.isReady, case .ready = loadState { loadState = .idle }
    }

    private func memoryWarning() {
        let state = holder.state
        Diagnostics.record("whisper memory warning state=\(state) \(Diagnostics.processSummary())")
        // A model of this size in memory is the first thing to give back: a
        // jetsam kill would lose the dictation, a missing Whisper pass loses
        // nothing (the Apple text stands).
        guard state == .ready || state == .loading else { return }
        Task { await release(reason: "memory-warning") }
    }
}

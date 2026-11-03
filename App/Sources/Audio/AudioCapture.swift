import AVFAudio
import Foundation
import HexMobileCore
import Synchronization

/// Microphone capture with `AVAudioEngine`.
///
/// The engine can run without a consumer: that is how a flow session keeps
/// the audio session (and the app) alive in the background while discarding
/// input until dictation starts. A transcription engine attaches a ``Sink``
/// to receive buffers and detaches it when done.
///
/// Route and hardware changes (Bluetooth headphones, CarPlay, a media
/// services reset) stop the engine. The owner observes
/// ``isConfigurationChange(_:)`` / media-services notifications and calls
/// ``restart()`` or ``rebuildAfterMediaServicesReset()``; ``isRunning``
/// reports the engine's real state, so a stopped engine is never mistaken
/// for a running one.
///
/// Threading: `start()`, `stop()`, `restart()` and the rebuild are called from
/// the main actor; the tap block runs on a real-time audio thread and only
/// touches the lock-protected state. The tap block is created in a
/// nonisolated method on purpose, so it carries no actor isolation.
final class AudioCapture: @unchecked Sendable {
    /// Receives input buffers in the hardware format. Called on the audio
    /// thread; the buffer is only valid during the call.
    typealias Sink = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    /// Where ``start()`` failed and which system error it was, for the
    /// diagnostics log. The message alone lost both: the OSStatus that
    /// matters, `'what'` (2003329396) on `engine.start`, came after the
    /// cut-off of the old log line (1 Nov 2026).
    struct Failure: Equatable, Sendable {
        enum Stage: String, Sendable {
            case setCategory
            case setActive
            case inputFormat
            case engineStart = "engine.start"
        }

        var stage: Stage
        /// The system error's `localizedDescription`.
        var message: String
        /// `NSError.domain` and `.code` of the system error; `nil` when the
        /// failure is ours (no usable input format).
        var domain: String?
        var code: Int?
        /// ``code`` as four characters when they are printable, like `what`.
        var fourCC: String?
        /// The input node's hardware format when `start()` got that far.
        var inputSampleRate: Double?
        var inputChannelCount: Int?

        init(stage: Stage, error: any Error, inputFormat: AVAudioFormat? = nil) {
            let nsError = error as NSError
            self.stage = stage
            message = error.localizedDescription
            domain = nsError.domain
            code = nsError.code
            fourCC = FourCC.string(for: nsError.code)
            inputSampleRate = inputFormat?.sampleRate
            inputChannelCount = inputFormat.map { Int($0.channelCount) }
        }

        init(stage: Stage, message: String, inputFormat: AVAudioFormat?) {
            self.stage = stage
            self.message = message
            inputSampleRate = inputFormat?.sampleRate
            inputChannelCount = inputFormat.map { Int($0.channelCount) }
        }
    }

    enum CaptureError: LocalizedError {
        case noInputAvailable(Failure)
        case sessionConfiguration(Failure)

        var failure: Failure {
            switch self {
            case let .noInputAvailable(failure), let .sessionConfiguration(failure): failure
            }
        }

        var errorDescription: String? {
            switch self {
            case .noInputAvailable:
                return String(localized: "No microphone input is available.")
            case let .sessionConfiguration(failure):
                // Same text as before: the stage prefix only for the two
                // session calls, the bare system message for the engine.
                // One interpolation keeps the localization key unchanged.
                let reason = switch failure.stage {
                case .setCategory, .setActive: "\(failure.stage.rawValue): \(failure.message)"
                case .inputFormat, .engineStart: failure.message
                }
                return String(localized: "The audio session could not start: \(reason)")
            }
        }
    }

    private struct State {
        var sink: Sink?
        var level: Float = 0
        var isRunning = false
        var inputFormat: AVAudioFormat?
        /// Buffers the tap delivered since a sink was last attached.
        var bufferCount = 0
        /// When the tap last delivered a buffer. Never reset, so a stopped
        /// or silent engine shows up as a growing age.
        var lastBufferAt: Date?
        /// A fallback of ``prepareRetry(_:)`` switched the session to the
        /// input-only `.record` category (see ``RetryVariant/recordOnly``).
        /// Until it is restored, ``start()`` keeps that category.
        var recordOnly = false
        #if DEBUG
        /// `-HexMobileSimulateWhat N`: how many `engine.start` calls still
        /// fail with a simulated `'what'` (Debug builds only).
        var simulatedWhatLeft = 0
        #endif
    }

    /// Liveness of the input tap, for the diagnostics log: a dictation that
    /// recognizes nothing is either a muted microphone (buffers arrive, level
    /// 0) or no audio at all (no buffers, a growing age).
    struct BufferStats: Sendable, Equatable {
        /// Buffers delivered since the sink was attached (the start of the
        /// dictation's recording).
        var count: Int
        /// Seconds since the last buffer; `nil` before the first one.
        var secondsSinceLast: TimeInterval?
    }

    var bufferStats: BufferStats {
        state.withLock { state in
            BufferStats(count: state.bufferCount, secondsSinceLast: state.lastBufferAt.map { Date().timeIntervalSince($0) })
        }
    }

    // Main actor only (replaced after a media services reset).
    private var engine = AVAudioEngine()
    private let state = Mutex(State())

    #if DEBUG
    init() {
        state.withLock { $0.simulatedWhatLeft = LaunchOptions.simulateWhatFailures }
    }
    #endif

    /// Whether the engine is capturing. False after the system stopped the
    /// engine (route or format change, media services reset).
    var isRunning: Bool { state.withLock { $0.isRunning } && engine.isRunning }

    /// Whether `notification` is a configuration change of this capture's engine.
    func isConfigurationChange(_ notification: Notification) -> Bool {
        notification.name == .AVAudioEngineConfigurationChange && (notification.object as AnyObject?) === engine
    }

    /// The hardware input format of the running engine.
    var inputFormat: AVAudioFormat? { state.withLock { $0.inputFormat } }

    /// Smoothed input level in 0...1 (for the level meter).
    var level: Float { state.withLock { $0.level } }

    /// Attaches or detaches the consumer of input buffers.
    func setSink(_ sink: Sink?) {
        state.withLock {
            $0.sink = sink
            if sink != nil { $0.bufferCount = 0 }
        }
    }

    /// Options of the normal category (`.playAndRecord`).
    static let categoryOptions: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]

    /// Sets the recording category only when it differs: from the background
    /// (Action Button) iOS refuses a category change with `!int`
    /// (560557684), but activating an already configured session works.
    /// The app also calls this at launch, so the category is in place before
    /// the first background start.
    static func configureCategory() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category == .playAndRecord, session.mode == .default,
           session.categoryOptions.isSuperset(of: categoryOptions) {
            return
        }
        try session.setCategory(.playAndRecord, mode: .default, options: categoryOptions)
    }

    /// What a failed flow-session start tries before the next attempt, from
    /// the second attempt on. Both are fallbacks: a start that works the
    /// first time never reaches them.
    enum RetryVariant: String, Sendable {
        /// The audio session goes through `setActive(false)`, the category is
        /// set again without the shortcut of ``configureCategory()``, and
        /// the session is activated again.
        case sessionReset = "session-reset"
        /// The session switches to `.record`: input only, no output unit.
        /// The log of 1 Nov 2026 shows `AUIOClient_StartIO` failing with
        /// `'what'` right after `output client: 2 ch, 0 Hz`, so the output
        /// side is the suspect (ipotesi: not confirmed). The price is
        /// `mixWithOthers`: other audio is interrupted while this runs.
        case recordOnly = "record-only"
    }

    /// `.record` takes only `.allowBluetoothHFP`; `mixWithOthers` and
    /// `defaultToSpeaker` are valid with `.playAndRecord` alone and make
    /// `setCategory` fail.
    static let recordOnlyOptions: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]

    /// The audio session as it is now, for the diagnostics log: category and
    /// options, the outputs of the current route (count and port types),
    /// sample rate, output channels and latency. The failed attempts of 1 Nov
    /// 2026 had an output unit of 0 Hz; this line shows the same thing from
    /// the session's side.
    static func routeSummary() -> String {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let ports = outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let category = session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")
        return "category=\(category) options=\(session.categoryOptions.rawValue) outputs=\(outputs.count)[\(ports)] "
            + "sr=\(Int(session.sampleRate)) outCh=\(session.outputNumberOfChannels) "
            + "outLatency=\(String(format: "%.4f", session.outputLatency))"
    }

    /// The category ``start()`` uses: the normal one, or `.record` while a
    /// fallback is in effect.
    private func configureSessionCategory() throws {
        guard state.withLock({ $0.recordOnly }) else {
            try Self.configureCategory()
            return
        }
        let session = AVAudioSession.sharedInstance()
        if session.category != .record {
            try session.setCategory(.record, mode: .default, options: Self.recordOnlyOptions)
        }
    }

    /// Activates the audio session and starts capturing. Idempotent while
    /// the engine really runs; after the system stopped it, starts again with
    /// the current hardware format.
    @MainActor func start() throws {
        if isRunning { return }
        if state.withLock({ $0.isRunning }) {
            // Stopped behind our back: drop the stale tap and format first.
            resetEngine()
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try configureSessionCategory()
        } catch {
            throw CaptureError.sessionConfiguration(Failure(stage: .setCategory, error: error))
        }
        do {
            try session.setActive(true, options: [])
        } catch {
            throw CaptureError.sessionConfiguration(Failure(stage: .setActive, error: error))
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputAvailable(Failure(stage: .inputFormat, message: "no usable input format", inputFormat: format))
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: makeTapBlock())
        engine.prepare()
        #if DEBUG
        let simulateWhat = state.withLock { state -> Bool in
            guard state.simulatedWhatLeft > 0 else { return false }
            state.simulatedWhatLeft -= 1
            return true
        }
        if simulateWhat {
            input.removeTap(onBus: 0)
            let error = NSError(domain: "com.apple.coreaudio.avfaudio", code: 2003329396,
                                userInfo: [NSLocalizedDescriptionKey: "simulated 'what' (debug)"])
            throw CaptureError.sessionConfiguration(Failure(stage: .engineStart, error: error, inputFormat: format))
        }
        #endif
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.sessionConfiguration(Failure(stage: .engineStart, error: error, inputFormat: format))
        }
        state.withLock {
            $0.isRunning = true
            $0.inputFormat = format
            $0.level = 0
        }
    }

    /// Stops capturing and deactivates the audio session. Idempotent.
    @MainActor func stop() {
        guard state.withLock({ $0.isRunning }) else { return }
        resetEngine()
        state.withLock { $0.sink = nil }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        restoreNormalCategory(cause: "stop")
    }

    /// After a configuration change: reinstalls the tap with the new hardware
    /// format and starts again. The sink is kept, so callers detach a sink
    /// built for the old format first.
    @MainActor func restart() throws {
        resetEngine()
        try start()
    }

    /// After `AVAudioSession.mediaServicesWereResetNotification`: the old
    /// engine is unusable, so it is replaced. Capture stays stopped and the
    /// sink is detached; the caller starts again if it still needs audio.
    func rebuildAfterMediaServicesReset() {
        // The old engine belongs to the reset media services: do not call it.
        engine = AVAudioEngine()
        state.withLock {
            $0.isRunning = false
            $0.inputFormat = nil
            $0.level = 0
            $0.sink = nil
            // The reset put the session back to its defaults.
            $0.recordOnly = false
        }
    }

    /// After a failed `start()` at the `engine.start` stage: the next attempt
    /// gets a new `AVAudioEngine`, so a half-initialised one is never reused.
    /// Unlike ``rebuildAfterMediaServicesReset()`` it leaves the sink alone,
    /// and it does not touch the audio session on purpose: from the
    /// background iOS can refuse to activate it again, so it stays active
    /// between attempts. The old engine is not called: `start()` removed its
    /// tap before it threw, and it never ran.
    func replaceEngineAfterFailedStart() {
        engine = AVAudioEngine()
        state.withLock {
            $0.isRunning = false
            $0.inputFormat = nil
            $0.level = 0
        }
    }

    /// Before the next attempt of a failed flow-session start (fallback
    /// only): resets the audio session as `variant` says and returns what
    /// each step did, for the diagnostics log. A step that fails is logged
    /// and does not stop the others: the attempt that follows decides.
    ///
    /// Everything runs in one synchronous turn on the main actor, with no
    /// suspension point between `setActive(false)` and the `setActive(true)`
    /// that ``start()`` performs next, so the app is never without an active
    /// audio session long enough to be suspended. That is also why the calls
    /// stay on the main thread although Xcode's thread-hang check flags
    /// `setActive` there (ipotesi: a few ms, not measured); moving them would
    /// put an `await` between the steps.
    @MainActor
    func prepareRetry(_ variant: RetryVariant) -> String {
        let session = AVAudioSession.sharedInstance()
        var steps: [String] = []
        @discardableResult
        func run(_ name: String, _ body: () throws -> Void) -> Bool {
            do {
                try body()
                steps.append("\(name)=ok")
                return true
            } catch {
                let code = (error as NSError).code
                steps.append("\(name)=\(FourCC.string(for: code) ?? String(code))")
                return false
            }
        }
        run("setActive(false)") { try session.setActive(false, options: [.notifyOthersOnDeactivation]) }
        switch variant {
        case .sessionReset:
            let categorySet = run("setCategory") { try session.setCategory(.playAndRecord, mode: .default, options: Self.categoryOptions) }
            if categorySet { state.withLock { $0.recordOnly = false } }
            run("setActive(true)") { try session.setActive(true, options: []) }
        case .recordOnly:
            let recordSet = run("setCategory(record)") { try session.setCategory(.record, mode: .default, options: Self.recordOnlyOptions) }
            if recordSet { state.withLock { $0.recordOnly = true } }
        }
        return "steps=[\(steps.joined(separator: " "))] \(Self.routeSummary())"
    }

    /// Back from `.record` to the normal category, best effort. From the
    /// background iOS can refuse a category change (`!int`); the flag then
    /// stays and the next ``start()`` keeps working with `.record` until the
    /// app is in the foreground (``configureCategoryForForeground()``).
    @MainActor
    @discardableResult
    private func restoreNormalCategory(cause: String) -> Bool {
        guard state.withLock({ $0.recordOnly }) else { return true }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: Self.categoryOptions)
            state.withLock { $0.recordOnly = false }
            Diagnostics.record("audio category restored cause=\(cause) \(Self.routeSummary())")
            return true
        } catch {
            let code = (error as NSError).code
            Diagnostics.record("audio category restore failed cause=\(cause) code=\(code) fourcc=\(FourCC.string(for: code) ?? "-") still=record")
            return false
        }
    }

    /// Restores the normal category when a fallback left `.record` behind and
    /// nothing is capturing (a start that gave up).
    @MainActor
    func restoreNormalCategoryIfIdle(cause: String) {
        guard state.withLock({ $0.recordOnly }), !isRunning else { return }
        restoreNormalCategory(cause: cause)
    }

    /// The category in place when the app is in the foreground. While a
    /// record-only fallback runs, it is left alone (switching the category
    /// under a running engine would disturb it); otherwise as at launch.
    @MainActor
    func configureCategoryForForeground() {
        if state.withLock({ $0.recordOnly }) {
            restoreNormalCategoryIfIdle(cause: "foreground")
            return
        }
        try? Self.configureCategory()
    }

    private func resetEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state.withLock {
            $0.isRunning = false
            $0.inputFormat = nil
            $0.level = 0
        }
    }

    private func makeTapBlock() -> AVAudioNodeTapBlock {
        { [weak self] buffer, time in
            guard let self else { return }
            let instantaneous = Self.normalizedLevel(of: buffer)
            let sink = self.state.withLock { state -> Sink? in
                // Fast attack, slow release, so the meter looks alive but calm.
                let factor: Float = instantaneous > state.level ? 0.6 : 0.15
                state.level += (instantaneous - state.level) * factor
                state.bufferCount += 1
                state.lastBufferAt = Date()
                return state.sink
            }
            sink?(buffer, time)
        }
    }

    /// RMS of the first channel mapped from -50...0 dBFS to 0...1.
    private static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 50) / 50, 0), 1)
    }
}

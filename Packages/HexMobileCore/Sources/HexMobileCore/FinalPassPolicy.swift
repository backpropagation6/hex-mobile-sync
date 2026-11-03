import Foundation

/// Time and acceptance rules of the steps that run after a dictation stops:
/// the accurate final pass over the recording, then the text cleanup.
///
/// The Action Button runs with the app in the background; the log of 1 Nov 2026
/// showed `backgroundTimeRemaining=32s` with no audio running. Both steps
/// share one budget well below that, and each one falls back to the text
/// it started from, so a slow or failed step never loses the dictation.
public enum FinalPassPolicy {
    /// From the stop to the finished text, for the final pass and the cleanup
    /// together.
    public static let totalBudget: TimeInterval = 8

    /// The share of the budget the final pass leaves to a cleanup of a short
    /// text. It sizes ``finalPassCeiling``; the cleanup's own time is
    /// ``cleanupPlan(elapsedSinceStop:characters:)``.
    public static let cleanupTimeout: TimeInterval = 3

    /// The longest the final pass may run: what the budget leaves after the
    /// cleanup.
    public static let finalPassCeiling: TimeInterval = totalBudget - cleanupTimeout

    /// What the text still needs after the cleanup returns (the guard, the
    /// spelling of the vocabulary, the history, the insertion), kept out of the
    /// budget: the cleanup must be over `endToEndMargin` before the 8 s. A
    /// choice made in place of the author (0.45 s, between the 0.4 and 0.5 asked
    /// for); the log line `stop to text dt=` is what measures it.
    public static let endToEndMargin: TimeInterval = 0.45

    /// When the cleanup must be over, in seconds after the stop: an absolute
    /// time, not a duration. A cleanup that has not returned by then is cut off.
    public static let cleanupDeadline: TimeInterval = totalBudget - endToEndMargin

    /// The shortest the final pass is given, whatever the recording length:
    /// the model has to load.
    public static let finalPassFloor: TimeInterval = 3

    /// How long the final pass may run for a recording of `seconds`.
    ///
    /// `2 s + 5 %` of the duration, between the floor and the ceiling. On the
    /// Mac the file pass runs at 0.01 to 0.02 times the audio duration
    /// (`asr-bench`, 104 s in 0.85 s). The iPhone factor is not measured
    /// (ipotesi: a few times slower); the `final pass dt=` log of the first
    /// dictations on the phone calibrates it. A recording so long that the
    /// pass cannot finish keeps its live text, which is what the fallback is for.
    public static func finalPassTimeout(forRecordingSeconds seconds: TimeInterval) -> TimeInterval {
        min(max(2 + 0.05 * max(0, seconds), finalPassFloor), finalPassCeiling)
    }

    /// What happens to the cleanup `elapsed` seconds after the stop, for a text
    /// of `characters`.
    public enum CleanupPlan: Equatable, Sendable {
        /// Start it, and give up at ``cleanupDeadline``: `timeout` is what is
        /// left of it now (a duration the caller turns into a deadline; ask
        /// again after any wait, with the clock as it is then).
        case run(timeout: TimeInterval)
        /// Not started: its estimate does not fit what is left (or what is left
        /// is below ``minimumCleanupTime``), and the text arrives as it is,
        /// logged `cleanup … outcome=fallback reason=budget`.
        case skip(estimate: TimeInterval, available: TimeInterval)
    }

    /// Decides whether the cleanup starts `elapsed` seconds after the stop.
    ///
    /// It starts if its point estimate (``cleanupEstimate(characters:)``, the
    /// same fit as the reserve Whisper leaves for it) fits what is left until
    /// ``cleanupDeadline``, and that is at least ``minimumCleanupTime``. Then its
    /// time is all of what is left, up to the deadline: it is not given a limit
    /// of its own. Before this a cleanup of 1890 characters (7.6 s estimated)
    /// started 1.3 s after the stop, ran for its 6.6 s limit and returned
    /// nothing (phone, 2 Nov 2026): the raw text arrived at 7.9 s after the stop,
    /// after a wait for nothing.
    public static func cleanupPlan(elapsedSinceStop elapsed: TimeInterval, characters: Int = 0) -> CleanupPlan {
        let available = cleanupDeadline - max(0, elapsed)
        let estimate = cleanupEstimate(characters: characters)
        if available < max(minimumCleanupTime, estimate) {
            return .skip(estimate: estimate, available: max(0, available))
        }
        return .run(timeout: available)
    }

    /// Below this a cleanup is not started: the model needs about a second.
    public static let minimumCleanupTime: TimeInterval = 1

    // MARK: - Cleanup time grows with the text

    /// The cleanup model writes the text again, so its time follows the length
    /// of the text: `0.25 s + 3.9 ms per character`. Fitted on the phone
    /// (2 Nov 2026): 86 to 87 characters in 0.55 to 0.63 s and 760 in 3.17 s;
    /// one run of 94 characters took 0.98 s, above the line. The Mac measured
    /// 190 and 312 words in 3.9 and 6.5 s, below it. The phone's batch 10
    /// measured 435 characters in 1.65 s, 1127 in 4.19 s: the line is above both.
    public static let cleanupFixedSeconds = 0.25
    public static let cleanupSecondsPerCharacter = 0.0039

    /// The time reserved for the cleanup when Whisper runs first is this much
    /// above the line: the phone's speed varies from one run to the next. The
    /// decision to start the cleanup uses the line itself.
    public static let cleanupMargin = 1.3

    /// Expected cleanup time for a text of `characters`: the one function that
    /// both the cleanup's own start (``cleanupPlan(elapsedSinceStop:characters:)``)
    /// and Whisper's reserve (``cleanupReserve(characters:)``) are worked out
    /// from.
    public static func cleanupEstimate(characters: Int) -> TimeInterval {
        cleanupFixedSeconds + cleanupSecondsPerCharacter * Double(max(0, characters))
    }

    /// Slack kept for the cleanup on top of its estimate when Whisper runs first.
    /// A Core ML prediction cannot be interrupted: when Whisper reaches its deadline
    /// the call returns, the model goes on for a moment on the Neural Engine, and the
    /// cleanup model starts on the same unit. Without it, a short text reserved just
    /// the ``minimumCleanupTime``, which is exactly what the cleanup's own guard needs
    /// to start, and a few hundredths of a second were enough to skip it. A choice
    /// made in place of the author (0.4 s, between the 0.3 and 0.5 asked for); no phone
    /// run has measured the contention.
    public static let whisperContentionMargin: TimeInterval = 0.4

    /// Time kept for the cleanup of a text of about `characters` when Whisper
    /// decides whether to start: the estimate with its margin, at least
    /// ``minimumCleanupTime`` (a cleanup shorter than that is not started), plus
    /// ``whisperContentionMargin``, plus ``endToEndMargin`` (the cleanup is over
    /// that long before the end of the budget). Whisper's deadline leaves the
    /// cleanup at least this much of the budget, so ``cleanupPlan(elapsedSinceStop:characters:)``
    /// always starts it, with at least `minimumCleanupTime + whisperContentionMargin`
    /// and its estimate.
    public static func cleanupReserve(characters: Int) -> TimeInterval {
        max(minimumCleanupTime, cleanupMargin * cleanupEstimate(characters: characters))
            + whisperContentionMargin + endToEndMargin
    }

    // MARK: - Whisper, the second engine

    /// Whisper runs after the Apple pass, if its estimated time and the
    /// estimated time of the cleanup both fit in what is left of the
    /// ``totalBudget``. On a long dictation they do not, and Apple's text goes
    /// to the cleanup: the formatted text is what the user asked for, and
    /// Whisper's gain does not pay for losing it (a choice made for the author
    /// by the coordinator on 2 Nov 2026, in place of a question the author asked not to
    /// be asked).
    ///
    /// The estimate has the form `fixed + piece × pieces + step × steps`,
    /// times a margin, with `steps = pieces × (prompt + 5) + tokens per second × audio`:
    /// a decoder step costs the same for a prompt token fed in as for a token written.
    /// The constants are fitted on four phone runs of 2 Nov 2026 (iPhone 16 Pro,
    /// Neural Engine; synthetic voice): 5.7 s with no prompt in 0.88 s, 4.8 s
    /// with a 100-token prompt in 2.34 s, and the 42 s clip in two windows, 4.18 s
    /// without the prompt and 6.59 s with it. With the real token counts the model
    /// is within 3 % of all four. The phone has not measured pieces yet: on the Mac
    /// they cost 0.35 to 0.45 s of encoder each, as the fit says.
    /// `whisper timings` and `whisper plan run estimate=` in the log are what
    /// replaces them (ipotesi: speakers faster than 6 tokens per second, or
    /// recordings of more than two pieces, run slower than the estimate says).
    public static let whisperFixedSeconds = 0.1
    /// One encoder pass of a 30 s window, whatever the piece length.
    public static let whisperSecondsPerPiece = 0.4
    /// One decoder step.
    public static let whisperSecondsPerStep = 0.015
    /// Tokens written per second of speech, for the estimate: measured 5.2 (Mac,
    /// synthetic) and 5.7 (phone); 6 leaves room for a quicker speaker.
    public static let whisperAssumedTokensPerSecond = 6.0
    /// The estimate is this much above the model: 25 % over the fit on the shortest
    /// clips it was measured on, and none to spare where it was not.
    public static let whisperEstimateMargin = 1.15

    /// How long Whisper is expected to take for `seconds` of audio read with a
    /// prompt of `promptTokens`.
    public static func whisperEstimate(forRecordingSeconds seconds: TimeInterval, promptTokens: Int = WhisperPromptBuilder.tokenCap) -> TimeInterval {
        let audio = max(0, seconds)
        let pieces = Double(max(1, WhisperClips.plannedPieces(recordingSeconds: audio, promptTokens: promptTokens)))
        // Without a prompt there is no `startofprev` token in front.
        let controlTokens = Double(WhisperClips.controlTokens - (promptTokens > 0 ? 0 : 1))
        let steps = pieces * (Double(max(0, promptTokens)) + controlTokens) + whisperAssumedTokensPerSecond * audio
        let modelSeconds = whisperFixedSeconds + whisperSecondsPerPiece * pieces + whisperSecondsPerStep * steps
        return whisperEstimateMargin * modelSeconds
    }

    /// What happens to Whisper at `elapsed` seconds after the stop.
    public enum WhisperPlan: Equatable, Sendable {
        /// Run it, and give up `endBy` seconds after the stop: an absolute time, not
        /// a duration. Whatever happens between the decision and the call (the Live
        /// Activity update is awaited) shortens the run, and the cleanup keeps its
        /// time; see ``whisperDeadline(endBy:elapsedSinceStop:)``.
        case run(endBy: TimeInterval)
        /// Not started: its estimate does not fit what is left.
        case skip(estimate: TimeInterval, available: TimeInterval)
    }

    /// How long Whisper may run when it starts `elapsed` seconds after the stop and
    /// has to give up at `endBy`. The caller reads the clock right before the call:
    /// the time spent since ``whisperPlan(recordingSeconds:elapsedSinceStop:promptTokens:cleanupCharacters:)``
    /// was asked is already out of it.
    public static func whisperDeadline(endBy: TimeInterval, elapsedSinceStop elapsed: TimeInterval) -> TimeInterval {
        endBy - max(0, elapsed)
    }

    /// Decides whether Whisper starts, after the Apple pass.
    ///
    /// Whisper must be done `endBy = totalBudget - reserve` seconds after the stop,
    /// where the reserve is the cleanup's (``cleanupReserve(characters:)``; nothing
    /// when no cleanup follows), so the cleanup keeps what it needs and the total
    /// stays inside the budget. The time Whisper has is `endBy - elapsed`: an estimate
    /// above that is not started, because running to the deadline and throwing the
    /// result away would only burn background CPU and delay the cleanup.
    ///
    /// Ask again after any wait that follows the decision (the controller does
    /// after awaiting the Live Activity), with the clock as it is then: the answer
    /// is the same `endBy`, or a skip when the wait ate the room.
    ///
    /// - Parameters:
    ///   - promptTokens: tokens of the vocabulary prompt (the cap when there are terms).
    ///   - cleanupCharacters: length of Apple's text when a cleanup follows;
    ///     `nil` when none does (setting off, model not available).
    public static func whisperPlan(
        recordingSeconds: TimeInterval,
        elapsedSinceStop elapsed: TimeInterval,
        promptTokens: Int = WhisperPromptBuilder.tokenCap,
        cleanupCharacters: Int? = nil
    ) -> WhisperPlan {
        let reserve = cleanupCharacters.map { cleanupReserve(characters: $0) } ?? 0
        let endBy = totalBudget - reserve
        let available = whisperDeadline(endBy: endBy, elapsedSinceStop: elapsed)
        let estimate = whisperEstimate(forRecordingSeconds: recordingSeconds, promptTokens: promptTokens)
        if available <= 0 || estimate > available { return .skip(estimate: estimate, available: max(0, available)) }
        return .run(endBy: endBy)
    }

    /// Consecutive words of Apple's text that Whisper's text may lack before
    /// Whisper is refused (``TranscriptGapGuard``).
    public static let whisperGapRun = TranscriptGapGuard.defaultMinimumRun

    /// Why the final pass text was not used.
    public enum Fallback: String, Sendable, Equatable {
        /// No recording to read (the file could not be written, or too short).
        case noAudio = "no-audio"
        /// The pass ran out of time.
        case timeout
        /// The pass threw.
        case error
        /// The pass returned nothing while the live transcript has words.
        case empty
        /// The pass returned less than half of the live words: it lost text.
        case short
        /// Whisper was not started: its estimate did not fit the budget left.
        case budget
        /// Whisper's model is not loaded yet (or not installed).
        case notReady = "not-ready"
        /// Whisper's text lacks a run of consecutive words of Apple's text
        /// (``TranscriptGapGuard``): a sentence was lost.
        case gap
    }

    /// The outcome of comparing the two transcripts.
    public enum Decision: Equatable, Sendable {
        case useFinal
        case useLive(Fallback)
    }

    /// Chooses between the live transcript and the final pass text.
    ///
    /// The final pass wins unless it is empty or has fewer than half of the
    /// live words. It is not judged on content: nothing here can tell which of
    /// two transcripts is more accurate, only that one of them lost text.
    public static func decide(live: String, final: String?) -> Decision {
        let liveWords = wordCount(live)
        let finalWords = final.map(wordCount) ?? 0
        if finalWords == 0 {
            return liveWords == 0 ? .useFinal : .useLive(.empty)
        }
        if liveWords > 0, finalWords * 2 < liveWords { return .useLive(.short) }
        return .useFinal
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

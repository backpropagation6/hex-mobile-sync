import Foundation
import HexMobileCore

/// Reads a recorded dictation and returns its text: the accurate second
/// opinion after the live transcript.
///
/// A small seam on purpose: the Apple implementation is
/// ``AppleFinalPassEngine``; Whisper (in the app, over WhisperKit) is a second
/// conformance, run after it in the time that is left.
public protocol FinalPassEngine: Sendable {
    /// Short name for logs and clip metadata, e.g. `speech-accurate`.
    var name: String { get }

    func transcribe(fileURL: URL, locale: Locale, contextualStrings: [String]) async throws -> String
}

/// `SpeechTranscriber` without `fastResults`, over the recorded file.
public struct AppleFinalPassEngine: FinalPassEngine {
    public init() {}

    public var name: String { RecognitionVariant.speechAccurate.rawValue }

    public func transcribe(fileURL: URL, locale: Locale, contextualStrings: [String]) async throws -> String {
        try await ClipTranscriber.transcribe(
            file: fileURL,
            locale: locale,
            variant: .speechAccurate,
            contextualStrings: contextualStrings
        ).text
    }
}

/// How one final pass went.
public struct FinalPassReport: Sendable, Equatable {
    public enum Outcome: String, Sendable { case ok, fallback }

    public var engine: String
    public var outcome: Outcome
    /// Why the text in hand stayed (`-` when the final pass was used).
    public var reason: String
    public var seconds: Double
    /// Characters of the text the pass was compared with.
    public var liveCharacters: Int
    public var finalCharacters: Int
    /// The text to go on with: the final pass, or the text in hand on a fallback.
    public var text: String
    /// The final pass text as returned (empty when it failed), for the clip metadata.
    public var rawFinal: String?
    /// Length of the recording, for the real-time factor (0: unknown).
    public var recordingSeconds: Double = 0
    /// What the text in hand is called in the log: `live` for the first pass,
    /// `apple` for Whisper, which is compared with Apple's text.
    public var baseline: String = "live"
    /// Set when the text was refused for lacking words of the text in hand
    /// (`reason=gap`).
    public var gap: TranscriptGapGuard.Gap?
    /// Set when the gap guard was asked for and did not run: the two texts
    /// were too long to align, and the pass text was used without being judged.
    public var guardNotJudged: NotJudged?

    /// What the log says when the guard did not run.
    public struct NotJudged: Sendable, Equatable {
        public var cells: Int
        public var referenceWords: Int
        public var finalWords: Int

        public init(cells: Int, referenceWords: Int, finalWords: Int) {
            self.cells = cells
            self.referenceWords = referenceWords
            self.finalWords = finalWords
        }
    }

    /// `guard gap=6 at=54 engine=whisper apple_words=120 final_words=114 unmatched=6 written=0`
    /// when ``gap`` is set (words of the text in hand and of the pass; `at` is
    /// the index of the first unmatched word of the text in hand; `gap=` is
    /// the net, `unmatched` and `written` the two counts it comes from, so the
    /// log says which rule refused). `guard skipped reason=too-long cells=…`
    /// when the texts were too long to compare. `nil` otherwise.
    public var guardLogLine: String? {
        if let gap {
            return "guard gap=\(gap.missing) at=\(gap.at) engine=\(engine) \(baseline)_words=\(WordErrorRate.words(in: text).count) final_words=\(WordErrorRate.words(in: rawFinal ?? "").count) unmatched=\(gap.unmatched) written=\(gap.written)"
        }
        if let guardNotJudged {
            return "guard skipped reason=too-long cells=\(guardNotJudged.cells) engine=\(engine) \(baseline)_words=\(guardNotJudged.referenceWords) final_words=\(guardNotJudged.finalWords)"
        }
        return nil
    }

    /// Seconds of work per second of audio, for a pass that ran to the end.
    public var realTimeFactor: Double? {
        guard outcome == .ok, recordingSeconds > 0 else { return nil }
        return seconds / recordingSeconds
    }

    /// `final pass dt=0.42 outcome=ok engine=speech-accurate reason=- live=110 final=118 rtf=0.04`
    ///
    /// `rtf` is only given for a pass that finished and was used; a timeout or
    /// an error says nothing about the speed of the model.
    public var logLine: String {
        let factor = realTimeFactor.map { String(format: "%.2f", $0) } ?? "-"
        return "final pass dt=\(String(format: "%.2f", seconds)) outcome=\(outcome.rawValue) engine=\(engine) reason=\(reason) \(baseline)=\(liveCharacters) final=\(finalCharacters) rtf=\(factor)"
    }
}

public enum FinalPass {
    /// A pass that was not started: the text in hand stays.
    public static func skipped(
        engine: String,
        reason: FinalPassPolicy.Fallback,
        text: String,
        recordingSeconds: TimeInterval = 0,
        baseline: String = "live"
    ) -> FinalPassReport {
        FinalPassReport(
            engine: engine, outcome: .fallback, reason: reason.rawValue, seconds: 0,
            liveCharacters: text.count, finalCharacters: 0, text: text, rawFinal: nil,
            recordingSeconds: recordingSeconds, baseline: baseline
        )
    }

    /// Runs the final pass over `fileURL` with a deadline and chooses between
    /// its text and the one in hand (``FinalPassPolicy/decide(live:final:)``).
    /// Never throws and never returns less than the text in hand.
    ///
    /// - Parameters:
    ///   - live: the text in hand: the live transcript for the first pass, the
    ///     Apple pass's text for the second.
    ///   - timeout: the deadline; the one of
    ///     ``FinalPassPolicy/finalPassTimeout(forRecordingSeconds:)`` when `nil`.
    ///   - baseline: how the text in hand is named in the log line.
    ///   - gapGuard: when set, the final pass text is also refused if it lacks
    ///     that many consecutive words of `live` (``TranscriptGapGuard``;
    ///     for Whisper against the text in hand, which is Apple's pass or, when
    ///     that fell back, the live transcript; not for the first pass against
    ///     the live transcript, which is the one with the errors). Texts too
    ///     long to compare pass unjudged and the report says so
    ///     (``FinalPassReport/guardNotJudged``).
    public static func run(
        engine: any FinalPassEngine,
        fileURL: URL?,
        locale: Locale,
        contextualStrings: [String],
        live: String,
        recordingSeconds: TimeInterval,
        timeout: TimeInterval? = nil,
        baseline: String = "live",
        gapGuard: Int? = nil
    ) async -> FinalPassReport {
        let started = ContinuousClock.now
        func elapsed() -> Double {
            let duration = started.duration(to: .now)
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        func fallback(_ reason: String, final: String? = nil, gap: TranscriptGapGuard.Gap? = nil) -> FinalPassReport {
            FinalPassReport(
                engine: engine.name, outcome: .fallback, reason: reason, seconds: elapsed(),
                liveCharacters: live.count, finalCharacters: final?.count ?? 0, text: live, rawFinal: final,
                recordingSeconds: recordingSeconds, baseline: baseline, gap: gap
            )
        }

        guard let fileURL else { return fallback(FinalPassPolicy.Fallback.noAudio.rawValue) }
        let timeout = timeout ?? FinalPassPolicy.finalPassTimeout(forRecordingSeconds: recordingSeconds)
        let final: String
        do {
            final = try await withDeadline(.seconds(timeout)) {
                try await engine.transcribe(fileURL: fileURL, locale: locale, contextualStrings: contextualStrings)
            }.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is DeadlineExceeded {
            return fallback(FinalPassPolicy.Fallback.timeout.rawValue)
        } catch {
            let nsError = error as NSError
            return fallback("\(FinalPassPolicy.Fallback.error.rawValue):\(nsError.domain)/\(nsError.code)")
        }

        switch FinalPassPolicy.decide(live: live, final: final) {
        case .useFinal:
            var notJudged: FinalPassReport.NotJudged?
            if let gapGuard {
                switch TranscriptGapGuard.judge(reference: live, candidate: final, minimumRun: gapGuard) {
                case let .refused(gap):
                    return fallback(FinalPassPolicy.Fallback.gap.rawValue, final: final, gap: gap)
                case let .notJudged(cells):
                    notJudged = FinalPassReport.NotJudged(
                        cells: cells,
                        referenceWords: WordErrorRate.words(in: live).count,
                        finalWords: WordErrorRate.words(in: final).count
                    )
                case .accepted:
                    break
                }
            }
            return FinalPassReport(
                engine: engine.name, outcome: .ok, reason: "-", seconds: elapsed(),
                liveCharacters: live.count, finalCharacters: final.count, text: final, rawFinal: final,
                recordingSeconds: recordingSeconds, baseline: baseline, guardNotJudged: notJudged
            )
        case let .useLive(reason):
            return fallback(reason.rawValue, final: final)
        }
    }
}

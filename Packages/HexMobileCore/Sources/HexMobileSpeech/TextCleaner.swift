import Foundation
import FoundationModels
import HexMobileCore
import NaturalLanguage
import Synchronization

/// Whether the on-device language model can clean text for a locale.
public enum CleanupAvailability: Sendable, Equatable {
    case available
    /// The model cannot be used; the value says why (`device-not-eligible`,
    /// `apple-intelligence-off`, `model-not-ready`, `language-unsupported`).
    case unavailable(String)

    public var isAvailable: Bool { self == .available }

    /// `available` or `unavailable:<reason>`, for the log.
    public var logValue: String {
        switch self {
        case .available: "available"
        case let .unavailable(reason): "unavailable:\(reason)"
        }
    }
}

/// How one cleanup went.
public struct CleanupReport: Sendable, Equatable {
    public enum Outcome: String, Sendable { case ok, fallback }

    public var outcome: Outcome
    /// Why the raw text stayed (`-` when the cleanup was used).
    public var reason: String
    public var seconds: Double
    public var inputCharacters: Int
    public var outputCharacters: Int
    /// The text to go on with: the cleaned text, or the input on a fallback.
    public var text: String
    /// The cleaned text when it was accepted.
    public var cleaned: String? { outcome == .ok ? text : nil }

    /// `cleanup dt=0.52 outcome=ok reason=- in=80 out=59`
    public var logLine: String {
        "cleanup dt=\(String(format: "%.2f", seconds)) outcome=\(outcome.rawValue) reason=\(reason) in=\(inputCharacters) out=\(outputCharacters)"
    }
}

/// Punctuation, capitals and disfluencies of a dictation, fixed by the
/// on-device language model (Apple Foundation Models, Apple Intelligence). The
/// text never leaves the device.
///
/// One instance cleans one dictation: it owns a new `LanguageModelSession`, made
/// (and prewarmed) when recording starts, never reused, because the context of
/// a session grows and carries one dictation into the next. The raw text always
/// stands when the model cannot be used, is slow, errs, or returns something
/// that is not a cleanup of the dictation (``CleanupGuard``).
public final class TextCleaner: @unchecked Sendable {
    /// The cleanup is not tried above this many characters: the context window
    /// is 4,096 tokens for instructions, prompt and answer together.
    public static let maximumCharacters = 3000

    /// The language check looks at texts of at least this many characters.
    static let languageCheckMinimum = 30

    public let availability: CleanupAvailability
    private let session: LanguageModelSession?
    private let languageCode: String
    private let used = Mutex(false)

    /// Whether the model can clean text in `locale` right now.
    public static func availability(for locale: Locale) -> CleanupAvailability {
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        switch model.availability {
        case .available:
            return model.supportsLocale(locale) ? .available : .unavailable("language-unsupported")
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible: return .unavailable("device-not-eligible")
            case .appleIntelligenceNotEnabled: return .unavailable("apple-intelligence-off")
            case .modelNotReady: return .unavailable("model-not-ready")
            @unknown default: return .unavailable("unknown")
            }
        }
    }

    /// Makes the session for one dictation and prewarms the model.
    public init(locale: Locale) {
        let code = locale.language.languageCode?.identifier ?? "it"
        languageCode = code
        availability = Self.availability(for: locale)
        if availability.isAvailable {
            let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
            let languageName = Locale(identifier: "it").localizedString(forLanguageCode: code) ?? code
            let session = LanguageModelSession(
                model: model,
                instructions: CleanupPrompt.instructions(languageName: languageName)
            )
            session.prewarm()
            self.session = session
        } else {
            session = nil
        }
    }

    /// Cleans `text`. Never throws and never returns less than the input: on
    /// any problem the report says why and carries the raw text.
    /// - Parameter timeout: the cleanup gives up after this long.
    public func clean(_ text: String, timeout: Duration) async -> CleanupReport {
        let started = ContinuousClock.now
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func report(_ outcome: CleanupReport.Outcome, _ reason: String, output: String? = nil) -> CleanupReport {
            let elapsed = started.duration(to: .now)
            return CleanupReport(
                outcome: outcome,
                reason: reason,
                seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                inputCharacters: input.count,
                outputCharacters: output?.count ?? 0,
                text: output ?? input
            )
        }

        guard let session else {
            if case let .unavailable(why) = availability { return report(.fallback, "unavailable:\(why)") }
            return report(.fallback, "unavailable")
        }
        let alreadyUsed = used.withLock { flag in
            defer { flag = true }
            return flag
        }
        if alreadyUsed { return report(.fallback, "session-used") }
        guard !input.isEmpty else { return report(.fallback, "empty-input") }
        guard input.count <= Self.maximumCharacters else { return report(.fallback, "too-long") }
        if input.count >= Self.languageCheckMinimum,
           let detected = Self.dominantLanguage(of: input), detected.code != languageCode {
            return report(.fallback, "language")
        }

        let options = GenerationOptions(
            samplingMode: .greedy,
            maximumResponseTokens: max(48, min(1000, input.count / 2 + 40))
        )
        let prompt = CleanupPrompt.prompt(for: input)
        let answer: String
        do {
            answer = try await withDeadline(timeout) {
                try await session.respond(to: prompt, options: options).content
            }
        } catch is DeadlineExceeded {
            return report(.fallback, "timeout")
        } catch {
            return report(.fallback, Self.classify(error))
        }

        switch CleanupGuard.check(input: input, output: answer) {
        case let .reject(rejection):
            return report(.fallback, rejection.rawValue)
        case let .accept(cleaned):
            if cleaned.count >= Self.languageCheckMinimum,
               let before = Self.dominantLanguage(of: input), let after = Self.dominantLanguage(of: cleaned),
               before.code != after.code {
                return report(.fallback, "language")
            }
            return report(.ok, "-", output: cleaned)
        }
    }

    // MARK: - Helpers

    /// The dominant language of `text` when the recognizer is fairly sure.
    static func dominantLanguage(of text: String) -> (code: String, confidence: Double)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.8 else { return nil }
        return (best.key.rawValue, best.value)
    }

    /// A short reason for an error from the model. The case name comes from
    /// the description, so this reads the iOS 26 `GenerationError` and the iOS 27
    /// `LanguageModelError` alike (the iOS 26 cases are deprecated on 27).
    static func classify(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        let description = String(describing: error)
        let name = String(description.prefix { $0.isLetter || $0.isNumber })
        switch name.lowercased() {
        case "guardrailviolation": return "guardrail"
        case "ratelimited": return "rate-limited"
        case "exceededcontextwindowsize", "contextsizeexceeded": return "context"
        case "refusal": return "refusal-error"
        case "unsupportedlanguageorlocale": return "language-unsupported"
        case "assetsunavailable": return "assets-unavailable"
        case "timeout": return "timeout"
        case "concurrentrequests": return "busy"
        default:
            // An unknown case: the domain and code say more than a type name.
            let ns = error as NSError
            return "error:\(ns.domain)/\(ns.code)"
        }
    }
}

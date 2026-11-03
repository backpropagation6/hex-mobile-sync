import Foundation

/// The vocabulary terms as a Whisper prompt: the tokens that go to the model
/// ahead of the transcript, so that names and jargon come out spelled the
/// way the user writes them.
public struct WhisperPrompt: Sendable, Equatable {
    /// Token ids for `DecodingOptions.promptTokens`, never more than the cap.
    public var tokens: [Int]
    /// Terms that fit.
    public var termsUsed: Int
    /// Distinct terms offered.
    public var termsOffered: Int

    /// `whisper prompt terms=9/12 tokens=31`
    public var logLine: String {
        "whisper prompt terms=\(termsUsed)/\(termsOffered) tokens=\(tokens.count)"
    }
}

public enum WhisperPromptBuilder {
    /// The most prompt tokens used. WhisperKit keeps the *last* 111 prompt
    /// tokens (`TextDecoder`: `suffix(maxPromptLen)`, `maxPromptLen` = 224 / 2 - 1)
    /// and silently drops the head of a longer prompt, so the cap is applied
    /// here: the terms that do not fit are left out whole, never cut.
    public static let tokenCap = 100

    /// Builds the prompt from `terms`, in order.
    ///
    /// The text is `" " + terms.joined(", ")`, the shape that was measured on
    /// the Mac (`asr-bench`: `--prompt "Vercel, Sanity, Hugging Face, ..."`).
    /// A term is added when the whole prompt still fits in `cap` tokens; one
    /// that does not fit is skipped and the next, shorter ones are tried.
    /// Duplicates (ignoring case) and empty terms are dropped.
    ///
    /// - Parameter encode: the Whisper tokenizer, with the special tokens
    ///   already filtered out (`id < specialTokenBegin`).
    public static func build(
        terms: [String],
        cap: Int = tokenCap,
        encode: (String) -> [Int]
    ) -> WhisperPrompt {
        var seen = Set<String>()
        var distinct: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            distinct.append(trimmed)
        }

        var accepted: [String] = []
        var tokens: [Int] = []
        for term in distinct {
            let candidate = accepted + [term]
            let encoded = encode(" " + candidate.joined(separator: ", "))
            guard encoded.count <= cap else { continue }
            accepted = candidate
            tokens = encoded
        }
        return WhisperPrompt(tokens: tokens, termsUsed: accepted.count, termsOffered: distinct.count)
    }
}

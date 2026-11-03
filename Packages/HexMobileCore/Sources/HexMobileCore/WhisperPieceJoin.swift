import Foundation

extension WhisperClips {
    /// The text of the pieces of one recording, put together.
    public struct Joined: Sendable, Equatable {
        public var text: String
        /// Pieces with some text.
        public var pieces: Int
        /// Pieces whose first letter was lowercased because the sentence went on.
        public var lowercased: Int

        /// `whisper join pieces=4 lowercased=2`
        public var logLine: String { "whisper join pieces=\(pieces) lowercased=\(lowercased)" }
    }

    /// Puts the text of the pieces together, one after the other as the
    /// decoder wrote them, lowercases the first letter of a piece that
    /// continues a sentence, and gives the whole text a capital at the start
    /// (``capitalizingFirstLetter(_:)``).
    ///
    /// Why: every piece is a window of its own, and the model starts a window as
    /// it starts a sentence, with a capital: a cut that falls after a comma gives
    /// «registrazioni, Perché» (2 Nov 2026). A piece that follows text ending in
    /// `.`, `!`, `?` or `…` (a closing quote or bracket after it is looked
    /// through) keeps its capital; one that follows a comma, a semicolon, a
    /// colon or a word without punctuation is lowercased.
    ///
    /// Not touched: the first piece; a word with two or more capitals (`IBAN`,
    /// `LoRA`, `Dell'Orto`); a piece that starts with a quote or a bracket (direct
    /// speech); in a language other than Italian the word `I`. What it cannot
    /// know is a proper name that is not one of the user's terms: «..., Bergamo»
    /// at the start of a piece becomes «..., bergamo». The user's terms get
    /// their spelling back from ``PersonalVocabulary/respell(_:terms:)`` further
    /// down, and the cleanup is the step that sees the rest.
    ///
    /// The pieces are joined as they come (the text of a window usually starts
    /// with a space): nothing is added, so a cut inside a word that the model
    /// continues without a space is still one word.
    ///
    /// - Parameters:
    ///   - pieces: the text of each piece, in order; empty ones are skipped.
    ///   - language: the language code of the recording (`it`); the Italian
    ///     article «I» is lowercased only for it.
    public static func join(_ pieces: [String], language: String? = nil) -> Joined {
        var text = ""
        var count = 0
        var lowercased = 0
        for piece in pieces {
            guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var current = piece
            if count > 0, !endsSentence(text), let lowered = loweringFirstLetter(of: piece, language: language) {
                current = lowered
                lowercased += 1
            }
            text += current
            count += 1
        }
        return Joined(
            text: capitalizingFirstLetter(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            pieces: count,
            lowercased: lowercased
        )
    }

    /// `text` with its first letter capitalized: the text of a dictation starts a
    /// sentence. Whisper writes it lowercase when the vocabulary prompt ends with
    /// a comma and the model goes on as if the sentence were already begun
    /// («sta andando proprio alla grande», 2 Nov 2026). Not touched: a text that
    /// starts with a digit, a quote, a bracket or any symbol (the same pieces
    /// ``join(_:language:)`` leaves alone when it lowercases), and a first word
    /// that already has a capital in it (`iPhone`, `eBay`), which is a spelling
    /// and not a sentence start.
    public static func capitalizingFirstLetter(_ text: String) -> String {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }),
              text[start].isLetter, text[start].isLowercase else { return text }
        let word = text[start...].prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        guard !word.contains(where: \.isUppercase) else { return text }
        var capitalized = text
        capitalized.replaceSubrange(start...start, with: text[start].uppercased())
        return capitalized
    }

    /// Closing marks looked through when asking how a text ends.
    private static let closingMarks: Set<Character> = ["\"", "'", "»", "”", "’", ")", "]"]

    /// Whether the last character that is not a space or a closing mark ends a sentence.
    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.reversed().first(where: { !$0.isWhitespace && !closingMarks.contains($0) }) else { return true }
        return ".!?…".contains(last)
    }

    /// `piece` with its first letter lowercased, or `nil` when it stays as it is.
    private static func loweringFirstLetter(of piece: String, language: String?) -> String? {
        guard let start = piece.firstIndex(where: { !$0.isWhitespace }),
              piece[start].isLetter, piece[start].isUppercase else { return nil }
        let word = piece[start...].prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        guard word.filter(\.isUppercase).count == 1 else { return nil }
        let isItalian = language?.lowercased().hasPrefix("it") == true
        if !isItalian, word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return nil }
        var lowered = piece
        lowered.replaceSubrange(start...start, with: piece[start].lowercased())
        return lowered
    }
}

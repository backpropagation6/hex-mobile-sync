import Foundation

/// Gives the user's own terms (names, brands, technical words) their exact
/// spelling in the dictated text.
///
/// The terms are the ones that already bias recognition: the Hex vocabulary
/// synced from the Mac plus the terms added on the iPhone
/// (``ContextualVocabulary``). The rewrite is deterministic and only touches
/// letter case: an occurrence that matches a term whole-word, ignoring case,
/// takes the term's spelling (`iphone` becomes `iPhone`). It never changes
/// letters, so `Marco` is never turned into `Mauro`; that is why the terms are
/// not given to the language model either (see ``CleanupPrompt``).
public enum PersonalVocabulary {
    public struct Result: Sendable, Equatable {
        public var text: String
        /// Occurrences whose spelling changed.
        public var changes: Int
    }

    /// Terms shorter than this are left to the recognizer: a one-letter match
    /// would fire on any word.
    static let minimumTermLength = 2

    /// `text` with every whole-word occurrence of a term written as the term.
    ///
    /// Terms without a capital letter or other case information (`hex`,
    /// `sanity` as typed in lowercase) change nothing: they only bias
    /// recognition. Longer terms are applied first, so `Claude Code` wins over
    /// `Claude`.
    public static func respell(_ text: String, terms: [String]) -> Result {
        let candidates = TermIdentity.uniquePhrases(terms)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { $0.count >= minimumTermLength && $0 != $0.lowercased() }
            .sorted { $0.count > $1.count }
        var current = text
        var changes = 0
        for term in candidates {
            let outcome = replacing(term, in: current)
            current = outcome.text
            changes += outcome.changes
        }
        return Result(text: current, changes: changes)
    }

    private static func replacing(_ term: String, in text: String) -> Result {
        var output = ""
        var changes = 0
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let range = text.range(of: term, options: .caseInsensitive, range: cursor..<text.endIndex) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            if isBoundary(before), isBoundary(after) {
                output += text[cursor..<range.lowerBound]
                if text[range] != term { changes += 1 }
                output += term
            } else {
                output += text[cursor..<range.upperBound]
            }
            cursor = range.upperBound
        }
        output += text[cursor...]
        return Result(text: output, changes: changes)
    }

    /// A word edge: the start or end of the text, or anything but a letter or
    /// digit (apostrophes and hyphens count as edges: `l'iphone`).
    private static func isBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        return !(character.isLetter || character.isNumber)
    }
}

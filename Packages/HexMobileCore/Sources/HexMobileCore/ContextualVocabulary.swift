import Foundation

/// Builds the term list used to bias on-device recognition
/// (`AnalysisContext.contextualStrings` in the Speech framework).
///
/// Only terms are used, never `sounds_like` phrases: the goal is to make the
/// recognizer produce the canonical spelling directly.
public enum ContextualVocabulary {
    /// The default maximum number of terms passed to the recognizer.
    public static let defaultLimit = 100

    /// The terms to pass as contextual strings.
    ///
    /// Synced vocabulary comes first, then pending iPhone terms, each in its
    /// original order. Terms are trimmed; blanks and duplicates (by
    /// ``TermIdentity``, first spelling wins) are dropped. The result has at
    /// most `limit` elements (a negative limit is treated as zero).
    public static func terms(
        vocabulary: [VocabularyEntry],
        pending: [PendingVocabularyEntry] = [],
        limit: Int = defaultLimit
    ) -> [String] {
        let cap = max(0, limit)
        guard cap > 0 else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for term in vocabulary.map(\.term) + pending.map(\.term) {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = TermIdentity.key(for: trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(trimmed)
            if result.count == cap { break }
        }
        return result
    }

    /// The terms for a synced bundle plus pending iPhone terms.
    /// See ``terms(vocabulary:pending:limit:)``.
    public static func terms(
        bundle: SyncBundle,
        pending: PendingVocabulary? = nil,
        limit: Int = defaultLimit
    ) -> [String] {
        terms(vocabulary: bundle.vocabulary, pending: pending?.entries ?? [], limit: limit)
    }
}

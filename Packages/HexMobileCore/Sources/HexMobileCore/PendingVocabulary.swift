import Foundation

// MARK: - Term identity

/// The identity rule used to decide whether two terms or phrases are "the same".
///
/// Two strings are the same term when, after trimming surrounding whitespace,
/// collapsing internal whitespace runs to one space and lowercasing, they are
/// equal. Comparison is case-insensitive but diacritic-sensitive: `Perché` and
/// `perché` are the same term, `perche` is a different one.
public enum TermIdentity {
    /// The identity key of `string`. Empty for blank input.
    public static func key(for string: String) -> String {
        string
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    /// Whether `lhs` and `rhs` are the same term.
    public static func same(_ lhs: String, _ rhs: String) -> Bool {
        key(for: lhs) == key(for: rhs)
    }

    /// Trims every phrase, drops blanks and duplicates (by ``key(for:)``),
    /// keeping the first spelling of each and the original order.
    public static func uniquePhrases(_ phrases: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for phrase in phrases {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let phraseKey = key(for: trimmed)
            guard !phraseKey.isEmpty, seen.insert(phraseKey).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

// MARK: - Pending vocabulary

/// A vocabulary term added on iPhone and waiting to be applied to Hex by the
/// Mac script.
///
/// JSON: `{ "id": "UUID", "term": "…", "sounds_like": ["…"], "created_at": "…" }`.
/// A missing or malformed `id` is replaced by a fresh UUID; a malformed
/// `created_at` becomes `nil`.
public struct PendingVocabularyEntry: Codable, Sendable, Hashable, Identifiable {
    /// Stable identifier, kept across merges.
    public var id: UUID
    /// The term to add to Hex.
    public var term: String
    /// Spellings to register for the term (`hex vocabulary add --sounds-like`).
    public var soundsLike: [String]
    /// When the entry was first created on the iPhone.
    public var createdAt: Date?

    /// Creates an entry. The term and phrases are stored as given; use
    /// ``PendingVocabulary/add(term:soundsLike:id:createdAt:)`` to get
    /// normalization and deduplication.
    public init(id: UUID = UUID(), term: String, soundsLike: [String] = [], createdAt: Date? = nil) {
        self.id = id
        self.term = term
        self.soundsLike = soundsLike
        self.createdAt = createdAt
    }

    /// The case-insensitive identity of ``term``.
    public var termKey: String { TermIdentity.key(for: term) }

    /// This entry as a plain vocabulary entry.
    public var vocabularyEntry: VocabularyEntry {
        VocabularyEntry(term: term, soundsLike: soundsLike)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case term
        case soundsLike = "sounds_like"
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLenient(UUID.self, forKey: .id) ?? UUID()
        term = try container.decode(String.self, forKey: .term)
        soundsLike = container.decodeLossyArray(String.self, forKey: .soundsLike)
        createdAt = container.decodeLenient(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(term, forKey: .term)
        try container.encode(soundsLike, forKey: .soundsLike)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

/// The contents of `pending-vocabulary.json`: terms added on iPhone that the
/// Mac script applies with `hex vocabulary add` and then removes.
///
/// Entries are unique by term identity (``TermIdentity``). Decoding merges
/// duplicates and drops blank terms, so a hand-edited file is normalized on
/// read. The same schema rules as ``SyncBundle`` apply.
public struct PendingVocabulary: Codable, Sendable, Hashable {
    /// The newest schema version this package reads and the one it writes.
    public static let currentSchemaVersion = 1

    /// Schema version of the document.
    public var schemaVersion: Int
    /// Pending entries, oldest first.
    public private(set) var entries: [PendingVocabularyEntry]

    /// The result of ``add(term:soundsLike:id:createdAt:)``.
    public enum AddOutcome: Sendable, Equatable {
        /// A new entry was appended.
        case added(PendingVocabularyEntry)
        /// New spellings were merged into an existing entry with the same term.
        case merged(PendingVocabularyEntry)
        /// The term and all its spellings were already pending.
        case unchanged(PendingVocabularyEntry)
        /// The term was blank.
        case rejectedBlankTerm
    }

    /// Creates a document. Entries are normalized as by ``add(_:)``.
    public init(entries: [PendingVocabularyEntry] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.entries = []
        for entry in entries { add(entry) }
    }

    /// Whether nothing is pending.
    public var isEmpty: Bool { entries.isEmpty }

    /// The pending entry for `term`, compared by ``TermIdentity``.
    public func entry(forTerm term: String) -> PendingVocabularyEntry? {
        let key = TermIdentity.key(for: term)
        return entries.first { $0.termKey == key }
    }

    /// Adds a term, or merges spellings into the pending entry with the same
    /// term identity.
    ///
    /// The term and phrases are trimmed, blank and duplicate phrases dropped.
    /// When the term is already pending, its `id`, spelling and `createdAt`
    /// are kept and only new phrases are appended.
    @discardableResult
    public mutating func add(
        term: String,
        soundsLike: [String] = [],
        id: UUID = UUID(),
        createdAt: Date? = Date()
    ) -> AddOutcome {
        add(PendingVocabularyEntry(id: id, term: term, soundsLike: soundsLike, createdAt: createdAt))
    }

    /// Adds an entry, merging it into an existing one with the same term identity.
    /// See ``add(term:soundsLike:id:createdAt:)``.
    @discardableResult
    public mutating func add(_ entry: PendingVocabularyEntry) -> AddOutcome {
        let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = TermIdentity.key(for: term)
        guard !key.isEmpty else { return .rejectedBlankTerm }
        let phrases = TermIdentity.uniquePhrases(entry.soundsLike)

        if let index = entries.firstIndex(where: { $0.termKey == key }) {
            var existing = entries[index]
            let merged = TermIdentity.uniquePhrases(existing.soundsLike + phrases)
            guard merged != existing.soundsLike else { return .unchanged(existing) }
            existing.soundsLike = merged
            if existing.createdAt == nil { existing.createdAt = entry.createdAt }
            entries[index] = existing
            return .merged(existing)
        }

        let normalized = PendingVocabularyEntry(
            id: entry.id,
            term: term,
            soundsLike: phrases,
            createdAt: entry.createdAt
        )
        entries.append(normalized)
        return .added(normalized)
    }

    /// Merges every entry of `other` into this document (union by term identity).
    /// Use it to reconcile a local copy with the file found on disk.
    public mutating func merge(_ other: PendingVocabulary) {
        for entry in other.entries { add(entry) }
    }

    /// The union of this document and `other`. See ``merge(_:)``.
    public func merging(_ other: PendingVocabulary) -> PendingVocabulary {
        var copy = self
        copy.merge(other)
        return copy
    }

    /// Removes the entry with `id`. Returns the removed entry, if any.
    @discardableResult
    public mutating func remove(id: UUID) -> PendingVocabularyEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: index)
    }

    /// Removes the entry for `term` (by term identity). Returns the removed entry, if any.
    @discardableResult
    public mutating func remove(term: String) -> PendingVocabularyEntry? {
        let key = TermIdentity.key(for: term)
        guard let index = entries.firstIndex(where: { $0.termKey == key }) else { return nil }
        return entries.remove(at: index)
    }

    /// Whether `entry` is already reflected in `vocabulary`: the term exists
    /// (by term identity) and every one of the entry's phrases is among that
    /// term's `sounds_like` (by term identity).
    public static func isApplied(_ entry: PendingVocabularyEntry, in vocabulary: [VocabularyEntry]) -> Bool {
        let key = entry.termKey
        let matching = vocabulary.filter { $0.termKey == key }
        guard !matching.isEmpty else { return false }
        let known = Set(matching.flatMap(\.soundsLike).map(TermIdentity.key(for:)))
        return entry.soundsLike.allSatisfy { known.contains(TermIdentity.key(for: $0)) }
    }

    /// A copy without the entries already applied to `vocabulary`
    /// (see ``isApplied(_:in:)``). Call it after reading a fresh bundle.
    public func removingApplied(in vocabulary: [VocabularyEntry]) -> PendingVocabulary {
        var copy = self
        copy.entries.removeAll { Self.isApplied($0, in: vocabulary) }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case entries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.validateSchemaVersion(
            forKey: .schemaVersion,
            supported: Self.currentSchemaVersion
        )
        self.init(entries: container.decodeLossyArray(PendingVocabularyEntry.self, forKey: .entries))
        schemaVersion = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(entries, forKey: .entries)
    }
}

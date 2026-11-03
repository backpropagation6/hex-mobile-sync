import Foundation

// MARK: - Errors

/// Errors raised while decoding the sync files exchanged with the Mac.
public enum SyncCodecError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The data is not valid JSON or does not have the expected top-level shape.
    case invalidJSON(String)
    /// The document has no integer `schema_version` field.
    case missingSchemaVersion
    /// The document was written for a schema this build does not understand
    /// (usually a newer Mac script). Update the app to read it.
    case unsupportedSchemaVersion(found: Int, supported: Int)

    public var description: String {
        switch self {
        case let .invalidJSON(detail):
            return "The sync file is not valid: \(detail)"
        case .missingSchemaVersion:
            return "The sync file has no schema_version; it was not written by Hex Mobile Sync."
        case let .unsupportedSchemaVersion(found, supported):
            return "The sync file uses schema version \(found), but this app supports up to \(supported). Update the app."
        }
    }
}

// MARK: - Vocabulary

/// One Hex vocabulary term with the spellings the transcriber may produce
/// for it. Mirrors the entries of `hex vocabulary list --json`.
///
/// JSON: `{ "term": "Kubernetes", "sounds_like": ["cooper netties"] }`.
/// `sounds_like` may be missing (treated as empty); non-string elements are skipped.
public struct VocabularyEntry: Codable, Sendable, Hashable {
    /// The canonical spelling written into the output.
    public var term: String
    /// Phrases rewritten to ``term`` by ``TextProcessor``.
    public var soundsLike: [String]

    /// Creates an entry.
    public init(term: String, soundsLike: [String] = []) {
        self.term = term
        self.soundsLike = soundsLike
    }

    /// The case-insensitive identity of ``term`` (see ``TermIdentity``).
    public var termKey: String { TermIdentity.key(for: term) }

    private enum CodingKeys: String, CodingKey {
        case term
        case soundsLike = "sounds_like"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        term = try container.decode(String.self, forKey: .term)
        soundsLike = container.decodeLossyArray(String.self, forKey: .soundsLike)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(term, forKey: .term)
        try container.encode(soundsLike, forKey: .soundsLike)
    }

    /// Merges entries that share a term identity (case-insensitive, trimmed,
    /// internal whitespace collapsed).
    ///
    /// The first entry's spelling of the term wins and keeps its position;
    /// `sounds_like` lists are unioned in order of first appearance, compared
    /// with the same identity. Entries whose term is blank are dropped, and
    /// blank `sounds_like` phrases are removed.
    public static func merged(_ entries: [VocabularyEntry]) -> [VocabularyEntry] {
        var order: [String] = []
        var byKey: [String: VocabularyEntry] = [:]
        for entry in entries {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = TermIdentity.key(for: term)
            guard !key.isEmpty else { continue }
            if var existing = byKey[key] {
                existing.soundsLike = TermIdentity.uniquePhrases(existing.soundsLike + entry.soundsLike)
                byKey[key] = existing
            } else {
                order.append(key)
                byKey[key] = VocabularyEntry(term: term, soundsLike: TermIdentity.uniquePhrases(entry.soundsLike))
            }
        }
        return order.compactMap { byKey[$0] }
    }
}

// MARK: - Replacements and modes

/// A Hex text replacement: every whole-word, case-insensitive occurrence of
/// ``matchedPhrase`` becomes ``output``.
///
/// JSON: `{ "matched_phrase": "x", "output": "y" }`. A missing `output` decodes
/// as the empty string (the phrase is deleted).
public struct Replacement: Codable, Sendable, Hashable {
    /// The phrase to look for.
    public var matchedPhrase: String
    /// The text written in its place.
    public var output: String

    /// Creates a replacement.
    public init(matchedPhrase: String, output: String) {
        self.matchedPhrase = matchedPhrase
        self.output = output
    }

    private enum CodingKeys: String, CodingKey {
        case matchedPhrase = "matched_phrase"
        case output
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        matchedPhrase = try container.decode(String.self, forKey: .matchedPhrase)
        output = container.decodeLenient(String.self, forKey: .output) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(matchedPhrase, forKey: .matchedPhrase)
        try container.encode(output, forKey: .output)
    }
}

/// A Hex dictation mode: replacements and transformations applied to a
/// transcript. The Global mode is ``SyncBundle/defaultMode``; app-specific
/// modes live in ``SyncBundle/modes``.
///
/// Mirrors the objects of Hex's `dictation_processing.default_mode` and
/// `dictation_processing.modes` settings. Hex's `post_processing` block (LLM
/// prompt and model) is never exported and is ignored when present.
public struct ProcessingMode: Codable, Sendable, Hashable {
    /// Display name, e.g. `Global` or `Terminal`.
    public var name: String
    /// macOS application names the mode applies to on the Mac (informational on iPhone).
    public var applications: [String]
    /// Web hosts the mode applies to on the Mac (informational on iPhone).
    public var browserHosts: [String]
    /// Replacements, applied after the vocabulary rewrite.
    public var replacements: [Replacement]
    /// Transformation ids, applied in order after the replacements.
    /// See ``BuiltInTransformation`` for the ids this package implements.
    public var transformations: [String]

    /// Creates a mode.
    public init(
        name: String,
        applications: [String] = [],
        browserHosts: [String] = [],
        replacements: [Replacement] = [],
        transformations: [String] = []
    ) {
        self.name = name
        self.applications = applications
        self.browserHosts = browserHosts
        self.replacements = replacements
        self.transformations = transformations
    }

    /// A mode that changes nothing.
    public static let passthrough = ProcessingMode(name: "Global")

    private enum CodingKeys: String, CodingKey {
        case name
        case applications
        case browserHosts = "browser_hosts"
        case replacements
        case transformations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.decodeLenient(String.self, forKey: .name) ?? ""
        applications = container.decodeLossyArray(String.self, forKey: .applications)
        browserHosts = container.decodeLossyArray(String.self, forKey: .browserHosts)
        replacements = container.decodeLossyArray(Replacement.self, forKey: .replacements)
        transformations = container.decodeLossyArray(String.self, forKey: .transformations)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(applications, forKey: .applications)
        try container.encode(browserHosts, forKey: .browserHosts)
        try container.encode(replacements, forKey: .replacements)
        try container.encode(transformations, forKey: .transformations)
    }
}

// MARK: - Bundle

/// Where a ``SyncBundle`` came from.
///
/// JSON: `{ "app": "Hex", "app_version": "3.1.1", "via": "cli" }`.
public struct SyncSource: Codable, Sendable, Hashable {
    /// Producing app, normally `Hex`.
    public var app: String?
    /// Version of the producing app, e.g. `3.1.1`.
    public var appVersion: String?
    /// How the data was read: `cli` (running Hex) or `settings-file`
    /// (read-only fallback when Hex is not running).
    public var via: String?

    /// Creates a source description.
    public init(app: String? = nil, appVersion: String? = nil, via: String? = nil) {
        self.app = app
        self.appVersion = appVersion
        self.via = via
    }

    private enum CodingKeys: String, CodingKey {
        case app
        case appVersion = "app_version"
        case via
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = container.decodeLenient(String.self, forKey: .app)
        appVersion = container.decodeLenient(String.self, forKey: .appVersion)
        via = container.decodeLenient(String.self, forKey: .via)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(app, forKey: .app)
        try container.encodeIfPresent(appVersion, forKey: .appVersion)
        try container.encodeIfPresent(via, forKey: .via)
    }
}

/// The contents of `hex-mobile-sync.json`, written by the Mac script and read
/// by the iPhone app.
///
/// Decoding is tolerant: unknown keys are ignored, missing arrays are empty,
/// malformed array elements are skipped, a malformed `exported_at` becomes
/// `nil`. Decoding refuses a missing `schema_version` and any version other
/// than ``currentSchemaVersion`` with a ``SyncCodecError``.
public struct SyncBundle: Codable, Sendable, Hashable {
    /// The newest schema version this package reads and the one it writes.
    public static let currentSchemaVersion = 1

    /// Schema version of the decoded document (always ``currentSchemaVersion`` today).
    public var schemaVersion: Int
    /// When the Mac script exported the bundle.
    public var exportedAt: Date?
    /// The app and channel that produced the data.
    public var source: SyncSource?
    /// Dictation language configured in Hex (BCP 47 code such as `it`), if any.
    public var language: String?
    /// Hex vocabulary.
    public var vocabulary: [VocabularyEntry]
    /// The Global mode; `nil` when the Mac had none.
    public var defaultMode: ProcessingMode?
    /// App-specific modes. On iPhone one of them can be chosen as a manual override.
    public var modes: [ProcessingMode]

    /// Creates a bundle at the current schema version.
    public init(
        exportedAt: Date? = nil,
        source: SyncSource? = nil,
        language: String? = nil,
        vocabulary: [VocabularyEntry] = [],
        defaultMode: ProcessingMode? = nil,
        modes: [ProcessingMode] = []
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
        self.source = source
        self.language = language
        self.vocabulary = vocabulary
        self.defaultMode = defaultMode
        self.modes = modes
    }

    /// The mode to apply on iPhone.
    ///
    /// - Parameter overrideName: name of a mode in ``modes`` chosen by the
    ///   user. Compared case-insensitively after trimming. `nil` or an unknown
    ///   name selects ``defaultMode``.
    /// - Returns: the override, else ``defaultMode``, else ``ProcessingMode/passthrough``.
    public func activeMode(overrideName: String? = nil) -> ProcessingMode {
        if let overrideName, let mode = mode(named: overrideName) {
            return mode
        }
        return defaultMode ?? .passthrough
    }

    /// Finds a mode in ``modes`` by name (case-insensitive, trimmed).
    public func mode(named name: String) -> ProcessingMode? {
        let key = TermIdentity.key(for: name)
        guard !key.isEmpty else { return nil }
        return modes.first { TermIdentity.key(for: $0.name) == key }
    }

    /// Whether two bundles carry the same content, ignoring ``exportedAt``.
    public func hasSameContent(as other: SyncBundle) -> Bool {
        var lhs = self
        var rhs = other
        lhs.exportedAt = nil
        rhs.exportedAt = nil
        return lhs == rhs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case exportedAt = "exported_at"
        case source
        case language
        case vocabulary
        case defaultMode = "default_mode"
        case modes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.validateSchemaVersion(
            forKey: .schemaVersion,
            supported: Self.currentSchemaVersion
        )
        exportedAt = container.decodeLenient(Date.self, forKey: .exportedAt)
        source = container.decodeLenient(SyncSource.self, forKey: .source)
        let language = container.decodeLenient(String.self, forKey: .language)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = (language?.isEmpty ?? true) ? nil : language
        vocabulary = container.decodeLossyArray(VocabularyEntry.self, forKey: .vocabulary)
        defaultMode = container.decodeLenient(ProcessingMode.self, forKey: .defaultMode)
        modes = container.decodeLossyArray(ProcessingMode.self, forKey: .modes)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(exportedAt, forKey: .exportedAt)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(vocabulary, forKey: .vocabulary)
        try container.encodeIfPresent(defaultMode, forKey: .defaultMode)
        try container.encode(modes, forKey: .modes)
    }
}

// MARK: - Codec

/// Reads and writes the sync folder files with the package's JSON settings
/// (ISO 8601 dates, sorted keys).
public enum SyncCodec {
    /// File name of the bundle written by the Mac.
    public static let bundleFileName = "hex-mobile-sync.json"
    /// File name of the pending vocabulary written by the iPhone.
    public static let pendingVocabularyFileName = "pending-vocabulary.json"
    /// File name of the optional history export written by the iPhone.
    public static let historyExportFileName = "iphone-history.jsonl"
    /// Suggested name of the iCloud Drive folder shared by Mac and iPhone.
    public static let suggestedFolderName = "Hex Mobile"

    /// Decodes `hex-mobile-sync.json`.
    /// - Throws: ``SyncCodecError``.
    public static func decodeBundle(from data: Data) throws(SyncCodecError) -> SyncBundle {
        try decode(SyncBundle.self, from: data)
    }

    /// Encodes a bundle (used by tests and tooling; the Mac script writes the real file).
    public static func encode(_ bundle: SyncBundle) throws -> Data {
        try HexJSON.makeEncoder().encode(bundle)
    }

    /// Decodes `pending-vocabulary.json`.
    /// - Throws: ``SyncCodecError``.
    public static func decodePendingVocabulary(from data: Data) throws(SyncCodecError) -> PendingVocabulary {
        try decode(PendingVocabulary.self, from: data)
    }

    /// Encodes `pending-vocabulary.json`.
    public static func encode(_ pending: PendingVocabulary) throws -> Data {
        try HexJSON.makeEncoder().encode(pending)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws(SyncCodecError) -> Value {
        do {
            return try HexJSON.makeDecoder().decode(Value.self, from: data)
        } catch let error as SyncCodecError {
            throw error
        } catch {
            throw .invalidJSON(HexJSON.describe(error))
        }
    }
}

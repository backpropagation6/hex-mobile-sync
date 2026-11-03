import Foundation

// MARK: - Record

/// One finished dictation kept in the on-device history.
public struct DictationRecord: Codable, Sendable, Hashable, Identifiable {
    /// Stable identifier (also used in ``DictationPayload``).
    public var id: UUID
    /// When the dictation finished.
    public var createdAt: Date
    /// The final text after ``TextProcessor``.
    public var text: String
    /// The transcript before processing, when it differs from ``text``: what
    /// the recognizer returned (the accurate final pass, or the live
    /// transcript when that pass could not improve on it).
    public var rawText: String?
    /// ``rawText`` after the on-device cleanup (punctuation, capitals,
    /// hesitations), before the Hex text rules. `nil` when the cleanup did not
    /// run, fell back to the raw text or changed nothing. Older records have
    /// no such field.
    public var cleanedText: String?
    /// Recording duration in seconds.
    public var duration: TimeInterval?
    /// Recognition locale identifier, e.g. `it-IT`.
    public var locale: String?
    /// Name of the processing mode applied.
    public var modeName: String?
    /// Identifier of the transcription engine, e.g. `on-device`.
    public var engine: String?

    /// Creates a record.
    public init(
        id: UUID = UUID(),
        createdAt: Date,
        text: String,
        rawText: String? = nil,
        cleanedText: String? = nil,
        duration: TimeInterval? = nil,
        locale: String? = nil,
        modeName: String? = nil,
        engine: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.duration = duration
        self.locale = locale
        self.modeName = modeName
        self.engine = engine
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case text
        case rawText = "raw_text"
        case cleanedText = "cleaned_text"
        case duration
        case locale
        case modeName = "mode_name"
        case engine
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        text = try container.decode(String.self, forKey: .text)
        rawText = container.decodeLenient(String.self, forKey: .rawText)
        cleanedText = container.decodeLenient(String.self, forKey: .cleanedText)
        duration = container.decodeLenient(Double.self, forKey: .duration)
        locale = container.decodeLenient(String.self, forKey: .locale)
        modeName = container.decodeLenient(String.self, forKey: .modeName)
        engine = container.decodeLenient(String.self, forKey: .engine)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(rawText, forKey: .rawText)
        try container.encodeIfPresent(cleanedText, forKey: .cleanedText)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(locale, forKey: .locale)
        try container.encodeIfPresent(modeName, forKey: .modeName)
        try container.encodeIfPresent(engine, forKey: .engine)
    }
}

// MARK: - Retention

/// How long history is kept, with the same choices as Hex's `history_retention`.
///
/// Periods are fixed durations, independent of calendar and time zone:
/// a day is 24 hours, a week 7 days, a month 30 days.
public enum HistoryRetention: String, Codable, CaseIterable, Sendable {
    /// Keep the last 24 hours.
    case day
    /// Keep the last 7 days (the default, as in Hex).
    case week
    /// Keep the last 30 days.
    case month
    /// Never delete automatically.
    case forever

    /// The default retention.
    public static let `default`: HistoryRetention = .week

    /// The kept period in seconds, `nil` for ``forever``.
    public var interval: TimeInterval? {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .forever: nil
        }
    }

    /// The oldest creation date still kept at `now`, `nil` for ``forever``.
    /// Records created exactly at the cutoff are kept.
    public func cutoff(at now: Date) -> Date? {
        interval.map { now.addingTimeInterval(-$0) }
    }

    /// Whether a record created at `date` is still kept at `now`.
    public func keeps(_ date: Date, at now: Date) -> Bool {
        guard let cutoff = cutoff(at: now) else { return true }
        return date >= cutoff
    }
}

// MARK: - Store

/// Errors raised by ``HistoryStore``.
public enum HistoryStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The history file was written by a newer version of the app. It is left
    /// untouched; nothing is read or written until the app is updated.
    case unsupportedSchemaVersion(found: Int, supported: Int)

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(found, supported):
            return "The history file uses schema version \(found), but this app supports up to \(supported)."
        }
    }
}

/// The on-device dictation history: a JSON file, newest record first, pruned
/// by ``HistoryRetention`` on every read and write.
///
/// File format: `{ "schema_version": 1, "records": [ DictationRecord… ] }`.
/// Writes are atomic (temporary file + rename). The parent directory is
/// created on first write.
///
/// Error handling:
/// - Missing file: empty history.
/// - Other read errors (permissions, I/O): thrown to the caller.
/// - Invalid JSON or an invalid layout: the file is moved aside to
///   `<name>.corrupt-<timestamp>.json` (see ``recoveredCorruptFileURL``) and
///   the history starts empty, so new dictations are not lost. Moved-aside
///   files can hold dictated text, so they follow the same rules as records:
///   removed by ``deleteAll()`` and, once older than the retention period,
///   by ``pruneExpired()``.
/// - Newer `schema_version`: ``HistoryStoreError/unsupportedSchemaVersion(found:supported:)``
///   is thrown and the file is never overwritten.
/// - Write failures are thrown to the caller; the in-memory state is not changed.
public actor HistoryStore {
    /// The newest schema version this store reads and the one it writes.
    public static let currentSchemaVersion = 1

    /// Location of the history file.
    public nonisolated let fileURL: URL
    /// The active retention policy.
    public private(set) var retention: HistoryRetention
    /// Where a corrupt history file was moved, if that happened in this session.
    public private(set) var recoveredCorruptFileURL: URL?

    private let now: @Sendable () -> Date
    private var cache: [DictationRecord]?

    /// Creates a store.
    /// - Parameters:
    ///   - fileURL: the JSON file, typically in Application Support.
    ///   - retention: the initial retention policy.
    ///   - now: the clock, injectable for tests.
    public init(
        fileURL: URL,
        retention: HistoryRetention = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.retention = retention
        self.now = now
    }

    /// All kept records, newest first. Expired records are pruned (and the
    /// file rewritten) first.
    public func records() throws -> [DictationRecord] {
        try pruneExpired()
        return try loaded()
    }

    /// The newest kept record, if any.
    public func latest() throws -> DictationRecord? {
        try records().first
    }

    /// Adds a record, replacing any record with the same id, then prunes.
    public func append(_ record: DictationRecord) throws {
        var records = try loaded()
        records.removeAll { $0.id == record.id }
        records.append(record)
        try save(records)
    }

    /// Deletes the record with `id`. Returns whether a record was deleted.
    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        var records = try loaded()
        let before = records.count
        records.removeAll { $0.id == id }
        guard records.count != before else { return false }
        try save(records)
        return true
    }

    /// Deletes every record, and every moved-aside corrupt copy of the file.
    public func deleteAll() throws {
        try save([])
        removeCorruptCopies(olderThan: nil)
    }

    /// Changes the retention policy and prunes immediately.
    public func setRetention(_ retention: HistoryRetention) throws {
        self.retention = retention
        try pruneExpired()
    }

    /// Removes records older than the retention period.
    /// - Returns: the number of records removed.
    @discardableResult
    public func pruneExpired() throws -> Int {
        let records = try loaded()
        let retained = retainedRecords(records)
        let removed = records.count - retained.count
        if removed > 0 { try save(retained) }
        if let cutoff = retention.cutoff(at: now()) {
            removeCorruptCopies(olderThan: cutoff)
        }
        return removed
    }

    /// The moved-aside corrupt copies of the history file, with the time they
    /// were moved (from their name).
    public nonisolated func corruptCopies() -> [(url: URL, movedAt: Date)] {
        let directory = fileURL.deletingLastPathComponent()
        let prefix = fileURL.deletingPathExtension().lastPathComponent + ".corrupt-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> (url: URL, movedAt: Date)? in
            guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return nil }
            let stamp = name.dropFirst(prefix.count).dropLast(".json".count)
                .split(separator: "-", maxSplits: 1).first.flatMap { TimeInterval(String($0)) }
            guard let stamp else { return nil }
            return (directory.appendingPathComponent(name), Date(timeIntervalSince1970: stamp))
        }
    }

    /// Drops the in-memory copy so the next call reads the file again.
    public func invalidateCache() {
        cache = nil
    }

    // MARK: Private

    private func retainedRecords(_ records: [DictationRecord]) -> [DictationRecord] {
        let now = self.now()
        return records
            .filter { retention.keeps($0.createdAt, at: now) }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString < $1.id.uuidString }
    }

    private func save(_ records: [DictationRecord]) throws {
        let retained = retainedRecords(records)
        let file = HistoryFile(schemaVersion: Self.currentSchemaVersion, records: retained)
        let data = try HexJSON.makeEncoder().encode(file)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        cache = retained
    }

    private func loaded() throws -> [DictationRecord] {
        if let cache { return cache }
        let records = try readFile()
        cache = records
        return records
    }

    private func readFile() throws -> [DictationRecord] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            if !FileManager.default.fileExists(atPath: fileURL.path) { return [] }
            throw error
        }

        let decoder = HexJSON.makeDecoder()
        do {
            let file = try decoder.decode(HistoryFile.self, from: data)
            return file.records
        } catch let error as HistoryStoreError {
            throw error
        } catch {
            try quarantineCorruptFile()
            return []
        }
    }

    /// Best effort: a copy that cannot be removed now is retried on the next prune.
    private func removeCorruptCopies(olderThan cutoff: Date?) {
        for copy in corruptCopies() where cutoff.map({ copy.movedAt < $0 }) ?? true {
            try? FileManager.default.removeItem(at: copy.url)
            if copy.url == recoveredCorruptFileURL { recoveredCorruptFileURL = nil }
        }
    }

    private func quarantineCorruptFile() throws {
        let stamp = Int(self.now().timeIntervalSince1970)
        let base = fileURL.deletingPathExtension().lastPathComponent
        let directory = fileURL.deletingLastPathComponent()
        var destination = directory.appendingPathComponent("\(base).corrupt-\(stamp).json")
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base).corrupt-\(stamp)-\(suffix).json")
            suffix += 1
        }
        try FileManager.default.moveItem(at: fileURL, to: destination)
        recoveredCorruptFileURL = destination
    }
}

/// On-disk layout of the history file.
private struct HistoryFile: Codable {
    var schemaVersion: Int
    var records: [DictationRecord]

    init(schemaVersion: Int, records: [DictationRecord]) {
        self.schemaVersion = schemaVersion
        self.records = records
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case records
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version <= HistoryStore.currentSchemaVersion else {
            throw HistoryStoreError.unsupportedSchemaVersion(
                found: version,
                supported: HistoryStore.currentSchemaVersion
            )
        }
        schemaVersion = version
        // Lossy: one malformed record does not discard the others.
        records = container.decodeLossyArray(DictationRecord.self, forKey: .records)
    }
}

// MARK: - Export

/// Writes history records as JSON Lines for the optional
/// `iphone-history.jsonl` export in the sync folder.
public enum HistoryExport {
    /// One compact JSON object per line, in the given order, each line ending
    /// with `\n`. Keys are sorted; dates are ISO 8601. Only the final text is
    /// exported: `raw_text` (the transcript before cleanup and text rules) and
    /// `cleaned_text` stay on the iPhone.
    public static func jsonLines(_ records: [DictationRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(HexJSON.formatDate(date))
        }
        var data = Data()
        for var record in records {
            record.rawText = nil
            record.cleanedText = nil
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        return data
    }
}

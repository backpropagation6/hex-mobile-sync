import Foundation

/// What the app knows about one kept recording. Written next to the audio as
/// `<id>.json`; the Mac tool `tools/asr-bench` reads it to compare what the
/// phone produced with what each recognizer variant produces on the same audio.
public struct ClipMetadata: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// The file stem of the clip (`clip-20261101-213045-1A2B3C`).
    public var id: String
    public var createdAt: Date
    public var seconds: Double
    public var locale: String?
    /// The audio input port (`MicrophoneBuiltIn`, `BluetoothHFP`…).
    public var route: String?
    /// The live (fast) transcript at the stop.
    public var liveText: String
    /// What the accurate final pass returned, when it ran and returned text.
    public var finalPassText: String?
    /// `ok`, `fallback:<reason>` or `skipped:<reason>`.
    public var finalPassOutcome: String?
    public var finalPassSeconds: Double?
    /// Whose text went on to the cleanup: `whisper`, the name of the Apple
    /// final pass engine, or `live` when the live transcript stood. Absent in
    /// clips kept before the Whisper engine existed.
    public var finalEngine: String?
    /// What the Whisper pass returned, when it was asked for and returned text
    /// (the Apple pass stays in `finalPassText`, so the two can be compared).
    public var whisperText: String?
    /// `ok` or `fallback:<reason>` (`budget`, `not-ready`, `timeout`, `short`…);
    /// absent when the Whisper engine was not chosen.
    public var whisperOutcome: String?
    public var whisperSeconds: Double?
    /// What the language model returned, when it was accepted.
    public var cleanedText: String?
    /// `ok`, `fallback:<reason>` or `skipped:<reason>`.
    public var cleanupOutcome: String?
    public var cleanupSeconds: Double?
    /// The text that was inserted (after vocabulary and Hex rules).
    public var insertedText: String
    /// From the stop to the text being ready.
    public var stopToTextSeconds: Double?
    /// The history record of the dictation.
    public var recordID: UUID?

    public init(
        id: String,
        createdAt: Date,
        seconds: Double,
        locale: String? = nil,
        route: String? = nil,
        liveText: String,
        finalPassText: String? = nil,
        finalPassOutcome: String? = nil,
        finalPassSeconds: Double? = nil,
        finalEngine: String? = nil,
        whisperText: String? = nil,
        whisperOutcome: String? = nil,
        whisperSeconds: Double? = nil,
        cleanedText: String? = nil,
        cleanupOutcome: String? = nil,
        cleanupSeconds: Double? = nil,
        insertedText: String,
        stopToTextSeconds: Double? = nil,
        recordID: UUID? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.createdAt = createdAt
        self.seconds = seconds
        self.locale = locale
        self.route = route
        self.liveText = liveText
        self.finalPassText = finalPassText
        self.finalPassOutcome = finalPassOutcome
        self.finalPassSeconds = finalPassSeconds
        self.finalEngine = finalEngine
        self.whisperText = whisperText
        self.whisperOutcome = whisperOutcome
        self.whisperSeconds = whisperSeconds
        self.cleanedText = cleanedText
        self.cleanupOutcome = cleanupOutcome
        self.cleanupSeconds = cleanupSeconds
        self.insertedText = insertedText
        self.stopToTextSeconds = stopToTextSeconds
        self.recordID = recordID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case createdAt = "created_at"
        case seconds
        case locale
        case route
        case liveText = "live_text"
        case finalPassText = "final_pass_text"
        case finalPassOutcome = "final_pass_outcome"
        case finalPassSeconds = "final_pass_seconds"
        case finalEngine = "final_engine"
        case whisperText = "whisper_text"
        case whisperOutcome = "whisper_outcome"
        case whisperSeconds = "whisper_seconds"
        case cleanedText = "cleaned_text"
        case cleanupOutcome = "cleanup_outcome"
        case cleanupSeconds = "cleanup_seconds"
        case insertedText = "inserted_text"
        case stopToTextSeconds = "stop_to_text_seconds"
        case recordID = "record_id"
    }

    /// A new clip id from the time and a short random suffix:
    /// `clip-20261101-213045-1A2B3C`.
    public static func makeID(at date: Date = Date(), suffix: String = String(UUID().uuidString.prefix(6))) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC") ?? .gmt, from: date)
        let stamp = String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        return "clip-\(stamp)-\(suffix)"
    }

    /// Decodes the JSON the app writes.
    public static func decode(from data: Data) throws -> ClipMetadata {
        try HexJSON.makeDecoder().decode(ClipMetadata.self, from: data)
    }

    /// Encodes the JSON the app writes (sorted keys, ISO 8601 dates).
    public func encoded() throws -> Data {
        try HexJSON.makeEncoder().encode(self)
    }
}

/// The recordings the user chose to keep to measure recognition: the newest
/// ``limit`` clips, each a `.caf` file with a `.json` of ``ClipMetadata``.
///
/// Local only: the directory is excluded from backups and nothing here is ever
/// written to the sync folder or exported with the history.
public struct ClipLibrary: Sendable {
    public static let defaultLimit = 20

    public let directory: URL
    public let limit: Int

    public init(directory: URL, limit: Int = defaultLimit) {
        self.directory = directory
        self.limit = max(1, limit)
    }

    public func audioURL(forID id: String) -> URL {
        directory.appending(path: "\(Self.safe(id)).caf")
    }

    public func metadataURL(forID id: String) -> URL {
        directory.appending(path: "\(Self.safe(id)).json")
    }

    /// Moves the recording at `audio` into the library (it is not copied: the
    /// same file the final pass read), writes its metadata and prunes the
    /// oldest clips beyond the limit. On a failure the audio file is left
    /// where it was.
    public func store(audio: URL, metadata: ClipMetadata) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)

        let target = audioURL(forID: metadata.id)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.moveItem(at: audio, to: target)
        do {
            try metadata.encoded().write(to: metadataURL(forID: metadata.id), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: target)
            throw error
        }
        for var url in [target, metadataURL(forID: metadata.id)] {
            try? url.setResourceValues(values)
        }
        prune()
    }

    /// The kept clips, newest first. Clips with unreadable metadata are
    /// skipped here and removed by ``prune()`` once they are the oldest.
    public func list() -> [ClipMetadata] {
        entries().compactMap(\.metadata).sorted { $0.createdAt > $1.createdAt }
    }

    public var count: Int { list().count }

    /// Deletes everything beyond the newest ``limit`` clips, and audio or
    /// metadata files that have lost their pair. Returns how many clips went.
    @discardableResult
    public func prune() -> Int {
        let all = entries()
        let ordered = all.sorted { ($0.metadata?.createdAt ?? .distantPast) > ($1.metadata?.createdAt ?? .distantPast) }
        var removed = 0
        for (index, entry) in ordered.enumerated() {
            let complete = entry.metadata != nil && entry.hasAudio
            if index >= limit || !complete {
                remove(id: entry.id)
                removed += 1
            }
        }
        return removed
    }

    /// Deletes every clip and its metadata. Returns how many clips went.
    @discardableResult
    public func deleteAll() -> Int {
        let all = entries()
        for entry in all { remove(id: entry.id) }
        return all.count
    }

    // MARK: - Private

    private struct Entry {
        var id: String
        var metadata: ClipMetadata?
        var hasAudio: Bool
    }

    private func entries() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let ids = Set(files.filter { ["caf", "json"].contains($0.pathExtension) }.map { $0.deletingPathExtension().lastPathComponent })
        return ids.map { id in
            let metadata = (try? Data(contentsOf: metadataURL(forID: id))).flatMap { try? ClipMetadata.decode(from: $0) }
            return Entry(id: id, metadata: metadata, hasAudio: FileManager.default.fileExists(atPath: audioURL(forID: id).path))
        }
    }

    private func remove(id: String) {
        try? FileManager.default.removeItem(at: audioURL(forID: id))
        try? FileManager.default.removeItem(at: metadataURL(forID: id))
    }

    /// Ids are file stems: nothing that could leave the directory.
    private static func safe(_ id: String) -> String {
        String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
    }
}

import Foundation
import Testing
@testable import HexMobileCore

@Suite("History store")
struct HistoryStoreTests {
    private let day: TimeInterval = 86_400

    private func record(_ text: String, at date: Date, id: UUID = UUID()) -> DictationRecord {
        DictationRecord(id: id, createdAt: date, text: text, rawText: text.lowercased(), duration: 2.5, locale: "it-IT", modeName: "Global", engine: "on-device")
    }

    @Test("Retention periods are fixed durations")
    func retentionIntervals() {
        #expect(HistoryRetention.default == .week)
        #expect(HistoryRetention.day.interval == day)
        #expect(HistoryRetention.week.interval == 7 * day)
        #expect(HistoryRetention.month.interval == 30 * day)
        #expect(HistoryRetention.forever.interval == nil)
        #expect(HistoryRetention.week.cutoff(at: referenceDate) == referenceDate.addingTimeInterval(-7 * day))
        #expect(HistoryRetention.day.keeps(referenceDate.addingTimeInterval(-day), at: referenceDate))
        #expect(!HistoryRetention.day.keeps(referenceDate.addingTimeInterval(-day - 1), at: referenceDate))
        #expect(HistoryRetention.forever.keeps(.distantPast, at: referenceDate))
        #expect(HistoryRetention.allCases.map(\.rawValue) == ["day", "week", "month", "forever"])
    }

    @Test("Missing file is an empty history; records persist across instances, newest first")
    func persistence() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let fileURL = directory.url.appendingPathComponent("nested/history.json")
        let clock = TestClock(referenceDate)

        let store = HistoryStore(fileURL: fileURL, now: clock.closure)
        #expect(try await store.records().isEmpty)

        let older = record("Prima", at: referenceDate.addingTimeInterval(-60))
        let newer = record("Perché è così?", at: referenceDate)
        try await store.append(older)
        try await store.append(newer)
        #expect(try await store.records().map(\.text) == ["Perché è così?", "Prima"])
        #expect(try await store.latest() == newer)

        let reopened = HistoryStore(fileURL: fileURL, now: clock.closure)
        #expect(try await reopened.records() == [newer, older])

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(contents.contains("\"schema_version\" : 1"))
        #expect(contents.contains("\"created_at\""))
        #expect(contents.contains("\"raw_text\""))
    }

    @Test("Appending a record with an existing id replaces it")
    func replaceByID() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let store = HistoryStore(fileURL: directory.url.appendingPathComponent("h.json"), now: { referenceDate })
        let id = UUID()
        try await store.append(record("old", at: referenceDate, id: id))
        try await store.append(record("new", at: referenceDate, id: id))
        #expect(try await store.records().map(\.text) == ["new"])
    }

    @Test("Delete and delete all")
    func deletion() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let store = HistoryStore(fileURL: directory.url.appendingPathComponent("h.json"), now: { referenceDate })
        let keep = record("keep", at: referenceDate)
        let drop = record("drop", at: referenceDate.addingTimeInterval(-1))
        try await store.append(keep)
        try await store.append(drop)
        #expect(try await store.delete(id: drop.id))
        #expect(try await !store.delete(id: drop.id))
        #expect(try await store.records() == [keep])
        try await store.deleteAll()
        #expect(try await store.records().isEmpty)
        await store.invalidateCache()
        #expect(try await store.records().isEmpty)
    }

    @Test("Retention prunes with the injected clock", arguments: [
        (HistoryRetention.day, 1),
        (HistoryRetention.week, 2),
        (HistoryRetention.month, 3),
        (HistoryRetention.forever, 4),
    ])
    func retentionPruning(retention: HistoryRetention, expectedCount: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let clock = TestClock(referenceDate)
        let store = HistoryStore(fileURL: directory.url.appendingPathComponent("h.json"), retention: .forever, now: clock.closure)
        for (index, age) in [0.5 * day, 3 * day, 20 * day, 400 * day].enumerated() {
            try await store.append(record("r\(index)", at: referenceDate.addingTimeInterval(-age)))
        }
        try await store.setRetention(retention)
        #expect(await store.retention == retention)
        #expect(try await store.records().count == expectedCount)
    }

    @Test("Advancing the clock expires records on the next read and rewrites the file")
    func clockAdvance() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let fileURL = directory.url.appendingPathComponent("h.json")
        let clock = TestClock(referenceDate)
        let store = HistoryStore(fileURL: fileURL, retention: .day, now: clock.closure)
        try await store.append(record("a", at: referenceDate))
        #expect(try await store.pruneExpired() == 0)

        clock.advance(by: day)
        #expect(try await store.records().count == 1, "Exactly at the cutoff the record is kept")

        clock.advance(by: 1)
        #expect(try await store.records().isEmpty)
        let reopened = HistoryStore(fileURL: fileURL, retention: .forever, now: clock.closure)
        #expect(try await reopened.records().isEmpty, "The pruned state was written to disk")
    }

    @Test("Appending an already expired record does not keep it")
    func appendExpired() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let store = HistoryStore(fileURL: directory.url.appendingPathComponent("h.json"), retention: .day, now: { referenceDate })
        try await store.append(record("old", at: referenceDate.addingTimeInterval(-2 * day)))
        #expect(try await store.records().isEmpty)
    }

    @Test("A corrupt file is moved aside and the history restarts empty")
    func corruptFile() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let fileURL = directory.url.appendingPathComponent("history.json")
        try Data("{ not json".utf8).write(to: fileURL)

        let store = HistoryStore(fileURL: fileURL, now: { referenceDate })
        #expect(try await store.records().isEmpty)
        let moved = try #require(await store.recoveredCorruptFileURL)
        #expect(moved.lastPathComponent == "history.corrupt-1793527200.json")
        #expect(try Data(contentsOf: moved) == Data("{ not json".utf8))

        try await store.append(record("after recovery", at: referenceDate))
        #expect(try await store.records().count == 1)
    }

    @Test("Corrupt copies are removed by Delete All and after the retention period")
    func corruptCopiesCleanup() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let fileURL = directory.url.appendingPathComponent("history.json")
        let clock = TestClock(referenceDate)
        try Data("{ not json".utf8).write(to: fileURL)

        let store = HistoryStore(fileURL: fileURL, retention: .day, now: clock.closure)
        #expect(try await store.records().isEmpty)
        #expect(store.corruptCopies().count == 1)
        // Still inside the retention period: kept.
        clock.advance(by: day - 1)
        #expect(try await store.records().isEmpty)
        #expect(store.corruptCopies().count == 1)
        // Older than the retention period: removed on the next prune.
        clock.advance(by: 2)
        #expect(try await store.records().isEmpty)
        #expect(store.corruptCopies().isEmpty)
        #expect(await store.recoveredCorruptFileURL == nil)

        // Delete All removes copies of any age.
        try Data("{ still not json".utf8).write(to: fileURL)
        let forever = HistoryStore(fileURL: fileURL, retention: .forever, now: clock.closure)
        #expect(try await forever.records().isEmpty)
        #expect(forever.corruptCopies().count == 1)
        try await forever.deleteAll()
        #expect(forever.corruptCopies().isEmpty)
        // Unrelated files in the directory are left alone.
        let other = directory.url.appendingPathComponent("history.corrupt-notes.txt")
        try Data("x".utf8).write(to: other)
        try await forever.deleteAll()
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test("One malformed record does not discard the others")
    func lossyRecords() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let fileURL = directory.url.appendingPathComponent("h.json")
        try json(#"""
        {"schema_version":1,"records":[
          {"id":"5D4C2B1A-0000-4000-8000-000000000001","created_at":"2026-11-01T09:00:00Z","text":"ok","unknown":true},
          {"id":"broken","text":"no date"}
        ]}
        """#).write(to: fileURL)
        let store = HistoryStore(fileURL: fileURL, now: { referenceDate })
        #expect(try await store.records().map(\.text) == ["ok"])
        #expect(await store.recoveredCorruptFileURL == nil)
    }

    @Test("A future schema throws and leaves the file untouched")
    func futureSchema() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let fileURL = directory.url.appendingPathComponent("h.json")
        let original = json(#"{"schema_version":2,"records":[]}"#)
        try original.write(to: fileURL)

        let store = HistoryStore(fileURL: fileURL, now: { referenceDate })
        await #expect(throws: HistoryStoreError.unsupportedSchemaVersion(found: 2, supported: 1)) {
            try await store.records()
        }
        await #expect(throws: HistoryStoreError.self) {
            try await store.append(record("x", at: referenceDate))
        }
        #expect(try Data(contentsOf: fileURL) == original)
    }

    @Test("Writes are atomic: no temporary files left behind")
    func atomicWrites() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let store = HistoryStore(fileURL: directory.url.appendingPathComponent("h.json"), now: { referenceDate })
        for index in 0..<5 {
            try await store.append(record("r\(index)", at: referenceDate.addingTimeInterval(Double(-index))))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        #expect(files == ["h.json"])
    }

    @Test("Concurrent appends from many tasks are all kept")
    func concurrentAppends() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.cleanup() }
        let store = HistoryStore(fileURL: directory.url.appendingPathComponent("h.json"), now: { referenceDate })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await store.append(DictationRecord(createdAt: referenceDate.addingTimeInterval(Double(-index)), text: "t\(index)"))
                }
            }
            try await group.waitForAll()
        }
        #expect(try await store.records().count == 20)
    }

    @Test("JSON Lines export: one sorted-key object per line")
    func jsonLinesExport() throws {
        let records = [
            DictationRecord(id: UUID(uuidString: "5D4C2B1A-0000-4000-8000-000000000001")!, createdAt: referenceDate, text: "Perché sì\nnuova riga"),
            DictationRecord(id: UUID(uuidString: "5D4C2B1A-0000-4000-8000-000000000002")!, createdAt: referenceDate, text: "l'API", locale: "it-IT"),
        ]
        let data = try HistoryExport.jsonLines(records)
        let text = try #require(String(data: data, encoding: .utf8))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3)
        #expect(lines.last == "")
        #expect(lines[0] == #"{"created_at":"2026-11-01T10:00:00.000Z","id":"5D4C2B1A-0000-4000-8000-000000000001","text":"Perché sì\nnuova riga"}"#)
        let decoded = try HexJSON.makeDecoder().decode(DictationRecord.self, from: Data(lines[1].utf8))
        #expect(decoded == records[1])
    }

    @Test("JSON Lines export leaves raw_text and cleaned_text on the iPhone")
    func jsonLinesExportOmitsRawText() throws {
        var withCleaned = record("Final text", at: referenceDate)
        withCleaned.cleanedText = "Final text."
        let data = try HistoryExport.jsonLines([withCleaned])
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("raw_text"))
        #expect(!text.contains("cleaned_text"))
        #expect(text.contains("Final text"))
    }

    @Test("A record keeps the raw and the cleaned text; one written before the field decodes without it")
    func cleanedTextRoundTrip() throws {
        var cleaned = record("Ciao Marco, a domani.", at: referenceDate)
        cleaned.rawText = "ehm ciao marco a domani"
        cleaned.cleanedText = "Ciao Marco, a domani."
        let encoder = HexJSON.makeEncoder()
        let data = try encoder.encode(cleaned)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"cleaned_text\""))
        #expect(try HexJSON.makeDecoder().decode(DictationRecord.self, from: data) == cleaned)

        // A history file from before the field existed.
        let old = json.replacingOccurrences(of: #","cleaned_text":"Ciao Marco, a domani.""#, with: "")
            .replacingOccurrences(of: #""cleaned_text" : "Ciao Marco, a domani.","#, with: "")
        let decoded = try HexJSON.makeDecoder().decode(DictationRecord.self, from: Data(old.utf8))
        #expect(decoded.cleanedText == nil)
        #expect(decoded.rawText == "ehm ciao marco a domani")
    }
}

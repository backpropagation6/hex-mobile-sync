import Foundation
import Testing
@testable import HexMobileCore

@Suite("Pending vocabulary")
struct PendingVocabularyTests {
    @Test("Term identity is case-insensitive, whitespace-normalized and diacritic-sensitive")
    func termIdentity() {
        #expect(TermIdentity.key(for: "  Example \t  Studio ") == "example studio")
        #expect(TermIdentity.same("Perché", "PERCHÉ"))
        #expect(!TermIdentity.same("perché", "perche"))
        #expect(TermIdentity.key(for: " \n ") == "")
        #expect(TermIdentity.uniquePhrases([" a ", "A", "", "b", "a  "]) == ["a", "b"])
    }

    @Test("Adding normalizes, merges by term identity and keeps the first id")
    func addAndMerge() throws {
        var pending = PendingVocabulary()
        let firstID = UUID()
        let added = pending.add(term: "  Fixture Term ", soundsLike: ["fixture turn", " ", "Fixture Turn"], id: firstID, createdAt: referenceDate)
        #expect(added == .added(PendingVocabularyEntry(id: firstID, term: "Fixture Term", soundsLike: ["fixture turn"], createdAt: referenceDate)))

        let merged = pending.add(term: "fixture term", soundsLike: ["FIXTURE TURN", "fixture terms"], createdAt: referenceDate.addingTimeInterval(60))
        #expect(merged == .merged(PendingVocabularyEntry(id: firstID, term: "Fixture Term", soundsLike: ["fixture turn", "fixture terms"], createdAt: referenceDate)))

        let unchanged = pending.add(term: "FIXTURE TERM", soundsLike: ["fixture terms"])
        guard case .unchanged = unchanged else {
            Issue.record("Expected unchanged, got \(unchanged)")
            return
        }
        #expect(pending.add(term: "   ", soundsLike: ["x"]) == .rejectedBlankTerm)
        #expect(pending.entries.count == 1)
        #expect(pending.entry(forTerm: "fixture term")?.id == firstID)
    }

    @Test("Decoding merges duplicates, drops blank or missing terms, tolerates bad ids and dates")
    func decodeFixture() throws {
        let pending = try SyncCodec.decodePendingVocabulary(from: fixtureData("pending-vocabulary"))
        #expect(pending.schemaVersion == 1)
        #expect(pending.entries.map(\.term) == ["Fixture Term", "Città Esempio"])
        let first = pending.entries[0]
        #expect(first.id == UUID(uuidString: "5D4C2B1A-0000-4000-8000-000000000001"))
        #expect(first.soundsLike == ["fixture turn", "fixture terms"])
        #expect(first.createdAt == referenceDate.addingTimeInterval(-30 * 60))
        let second = pending.entries[1]
        #expect(second.createdAt == nil)
        #expect(second.soundsLike == ["citta esempio"])
    }

    @Test("Round-trips with the PLAN's keys")
    func roundTrip() throws {
        var pending = PendingVocabulary()
        pending.add(term: "Città Esempio", soundsLike: ["citta esempio"], createdAt: referenceDate)
        pending.add(term: "Senza Data", soundsLike: [], createdAt: nil)
        let data = try SyncCodec.encode(pending)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schema_version", "entries"])
        let entries = try #require(object["entries"] as? [[String: Any]])
        #expect(Set(entries[0].keys) == ["id", "term", "sounds_like", "created_at"])
        #expect(Set(entries[1].keys) == ["id", "term", "sounds_like"])
        #expect(try SyncCodec.decodePendingVocabulary(from: data) == pending)
    }

    @Test("A future schema version is refused")
    func futureSchema() {
        #expect(throws: SyncCodecError.unsupportedSchemaVersion(found: 2, supported: 1)) {
            try SyncCodec.decodePendingVocabulary(from: json(#"{"schema_version":2,"entries":[]}"#))
        }
        #expect(throws: SyncCodecError.missingSchemaVersion) {
            try SyncCodec.decodePendingVocabulary(from: json(#"{"entries":[]}"#))
        }
    }

    @Test("Missing entries decode as empty")
    func missingEntries() throws {
        #expect(try SyncCodec.decodePendingVocabulary(from: json(#"{"schema_version":1}"#)).isEmpty)
    }

    @Test("Merging two documents is a union by term identity")
    func mergeDocuments() {
        var local = PendingVocabulary()
        let localID = UUID()
        local.add(term: "Alpha", soundsLike: ["alfa"], id: localID)
        local.add(term: "Beta", soundsLike: [])

        var disk = PendingVocabulary()
        disk.add(term: "alpha", soundsLike: ["al fa"])
        disk.add(term: "Gamma", soundsLike: ["gama"])

        let merged = local.merging(disk)
        #expect(merged.entries.map(\.term) == ["Alpha", "Beta", "Gamma"])
        #expect(merged.entries[0].id == localID)
        #expect(merged.entries[0].soundsLike == ["alfa", "al fa"])
        #expect(disk.merging(local).entries.map(\.term) == ["alpha", "Gamma", "Beta"])
    }

    @Test("Removing by id and by term")
    func removal() {
        var pending = PendingVocabulary()
        let id = UUID()
        pending.add(term: "One", id: id)
        pending.add(term: "Two")
        #expect(pending.remove(id: id)?.term == "One")
        #expect(pending.remove(id: id) == nil)
        #expect(pending.remove(term: "two")?.term == "Two")
        #expect(pending.isEmpty)
    }

    @Test("Entries already in the synced vocabulary are dropped as applied")
    func removingApplied() {
        var pending = PendingVocabulary()
        pending.add(term: "Applied", soundsLike: ["a plied"])
        pending.add(term: "Partly", soundsLike: ["part lee", "partially"])
        pending.add(term: "New Term", soundsLike: [])
        pending.add(term: "No Spellings", soundsLike: [])

        let vocabulary = [
            VocabularyEntry(term: "applied", soundsLike: ["A PLIED", "other"]),
            VocabularyEntry(term: "Partly", soundsLike: ["part lee"]),
            VocabularyEntry(term: "no spellings", soundsLike: ["whatever"]),
        ]
        let remaining = pending.removingApplied(in: vocabulary)
        #expect(remaining.entries.map(\.term) == ["Partly", "New Term"])
    }
}

@Suite("Contextual vocabulary")
struct ContextualVocabularyTests {
    @Test("Terms only, deduplicated case-insensitively, synced before pending")
    func ordering() {
        let terms = ContextualVocabulary.terms(
            vocabulary: [
                VocabularyEntry(term: "Kubernetes", soundsLike: ["cooper netties"]),
                VocabularyEntry(term: " perché ", soundsLike: ["perche"]),
                VocabularyEntry(term: "KUBERNETES"),
                VocabularyEntry(term: "  "),
            ],
            pending: [
                PendingVocabularyEntry(term: "Perché"),
                PendingVocabularyEntry(term: "Città Esempio"),
            ]
        )
        #expect(terms == ["Kubernetes", "perché", "Città Esempio"])
    }

    @Test("Capped at 100 by default and at any explicit limit")
    func cap() {
        let vocabulary = (0..<150).map { VocabularyEntry(term: "Term \($0)") }
        let terms = ContextualVocabulary.terms(vocabulary: vocabulary)
        #expect(ContextualVocabulary.defaultLimit == 100)
        #expect(terms.count == 100)
        #expect(terms.first == "Term 0")
        #expect(terms.last == "Term 99")
        #expect(ContextualVocabulary.terms(vocabulary: vocabulary, limit: 3) == ["Term 0", "Term 1", "Term 2"])
        #expect(ContextualVocabulary.terms(vocabulary: vocabulary, limit: 0).isEmpty)
        #expect(ContextualVocabulary.terms(vocabulary: vocabulary, limit: -1).isEmpty)
    }

    @Test("Bundle overload includes pending entries")
    func bundleOverload() throws {
        let bundle = try SyncCodec.decodeBundle(from: fixtureData("bundle-v1"))
        var pending = PendingVocabulary()
        pending.add(term: "Extra")
        let terms = ContextualVocabulary.terms(bundle: bundle, pending: pending)
        #expect(terms == ["Kubernetes", "PostgreSQL", "perché", "Example Studio", "SwiftUI", "Extra"])
    }
}

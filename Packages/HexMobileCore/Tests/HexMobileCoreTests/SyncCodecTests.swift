import Foundation
import Testing
@testable import HexMobileCore

@Suite("Sync bundle codec")
struct SyncCodecTests {
    @Test("Decodes a real-shaped bundle")
    func decodesFixture() throws {
        let bundle = try SyncCodec.decodeBundle(from: fixtureData("bundle-v1"))

        #expect(bundle.schemaVersion == 1)
        #expect(bundle.exportedAt == referenceDate)
        #expect(bundle.source == SyncSource(app: "Hex", appVersion: "3.1.1", via: "cli"))
        #expect(bundle.language == "it")
        #expect(bundle.vocabulary.count == 5)
        #expect(bundle.vocabulary[2] == VocabularyEntry(term: "perché", soundsLike: ["perche"]))
        #expect(bundle.vocabulary[4] == VocabularyEntry(term: "SwiftUI", soundsLike: []))
        #expect(bundle.defaultMode?.name == "Global")
        #expect(bundle.defaultMode?.replacements.first == Replacement(matchedPhrase: "punto e virgola", output: ";"))
        #expect(bundle.defaultMode?.replacements.last?.output == "\n")
        #expect(bundle.modes.map(\.name) == ["Terminal", "Chat"])
        #expect(bundle.modes[0].applications == ["Terminal", "ExampleTerm"])
        #expect(bundle.modes[1].browserHosts == ["chat.example.com"])
        #expect(bundle.modes[1].transformations == ["lowercase", "my-personal-command"])
    }

    @Test("Builds a bundle from real-shaped Hex CLI replies; post_processing is dropped")
    func composesFromHexCLIReplies() throws {
        struct VocabularyReply: Decodable {
            let version: Int
            let status: String
            let entries: [VocabularyEntry]
        }
        struct SettingsReply: Decodable {
            struct Setting: Decodable {
                let key: String
                let value: SettingValue
            }
            enum SettingValue: Decodable {
                case mode(ProcessingMode)
                case modes([ProcessingMode])

                init(from decoder: any Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let modes = try? container.decode([ProcessingMode].self) {
                        self = .modes(modes)
                    } else {
                        self = .mode(try container.decode(ProcessingMode.self))
                    }
                }
            }
            let version: Int
            let status: String
            let settings: [Setting]
        }

        let decoder = JSONDecoder()
        let vocabulary = try decoder.decode(VocabularyReply.self, from: fixtureData("hex-cli-vocabulary-list"))
        let settings = try decoder.decode(SettingsReply.self, from: fixtureData("hex-cli-settings-dictation-processing"))
        #expect(vocabulary.status == "vocabulary")
        #expect(settings.status == "settings")

        var defaultMode: ProcessingMode?
        var modes: [ProcessingMode] = []
        for setting in settings.settings {
            switch (setting.key, setting.value) {
            case ("dictation_processing.default_mode", .mode(let mode)): defaultMode = mode
            case ("dictation_processing.modes", .modes(let list)): modes = list
            default: Issue.record("Unexpected setting \(setting.key)")
            }
        }

        let bundle = SyncBundle(
            exportedAt: referenceDate,
            source: SyncSource(app: "Hex", appVersion: "3.1.1", via: "cli"),
            language: "it",
            vocabulary: vocabulary.entries,
            defaultMode: defaultMode,
            modes: modes
        )
        let data = try SyncCodec.encode(bundle)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("post_processing"))
        #expect(!text.contains("prompt"))

        let fixture = try SyncCodec.decodeBundle(from: fixtureData("bundle-v1"))
        #expect(try SyncCodec.decodeBundle(from: data).vocabulary == fixture.vocabulary)
        #expect(bundle.defaultMode == fixture.defaultMode)
        #expect(bundle.modes.first == fixture.modes.first)
    }

    @Test("Vocabulary entries decode straight from a CLI entries array")
    func vocabularyEntriesFromCLIArray() throws {
        let data = json(#"[{"term":"Città","sounds_like":["citta"]},{"term":"Solo"}]"#)
        let entries = try JSONDecoder().decode([VocabularyEntry].self, from: data)
        #expect(entries == [
            VocabularyEntry(term: "Città", soundsLike: ["citta"]),
            VocabularyEntry(term: "Solo", soundsLike: []),
        ])
    }

    @Test("Missing arrays decode as empty; missing default mode is nil")
    func minimalBundle() throws {
        let bundle = try SyncCodec.decodeBundle(from: json(#"{"schema_version":1}"#))
        #expect(bundle.vocabulary.isEmpty)
        #expect(bundle.modes.isEmpty)
        #expect(bundle.defaultMode == nil)
        #expect(bundle.exportedAt == nil)
        #expect(bundle.language == nil)
        #expect(bundle.activeMode() == .passthrough)
    }

    @Test("Null and wrongly typed collections decode as empty")
    func nullCollections() throws {
        let bundle = try SyncCodec.decodeBundle(from: json(#"""
        {"schema_version":1,"vocabulary":null,"modes":"oops","language":"  ",
         "default_mode":{"name":"Global","replacements":null,"transformations":"lowercase"}}
        """#))
        #expect(bundle.vocabulary.isEmpty)
        #expect(bundle.modes.isEmpty)
        #expect(bundle.language == nil)
        #expect(bundle.defaultMode == ProcessingMode(name: "Global"))
    }

    @Test("Malformed array elements are skipped, valid ones kept")
    func lossyElements() throws {
        let bundle = try SyncCodec.decodeBundle(from: json(#"""
        {"schema_version":1,
         "vocabulary":[{"sounds_like":["no term"]},{"term":"Valid","sounds_like":["ok",42,null,"also ok"]},7],
         "default_mode":{"name":"Global","replacements":[{"output":"x"},{"matched_phrase":"a","output":"b"},{"matched_phrase":"drop me"}]}}
        """#))
        #expect(bundle.vocabulary == [VocabularyEntry(term: "Valid", soundsLike: ["ok", "also ok"])])
        #expect(bundle.defaultMode?.replacements == [
            Replacement(matchedPhrase: "a", output: "b"),
            Replacement(matchedPhrase: "drop me", output: ""),
        ])
    }

    @Test("Unknown keys at every level are ignored")
    func unknownKeys() throws {
        let bundle = try SyncCodec.decodeBundle(from: json(#"""
        {"schema_version":1,"new_top":{"x":1},"vocabulary":[{"term":"T","sounds_like":[],"weight":3}],
         "modes":[{"name":"M","icon":"star","post_processing":{"enabled":true,"prompt":"p"}}]}
        """#))
        #expect(bundle.vocabulary == [VocabularyEntry(term: "T")])
        #expect(bundle.modes == [ProcessingMode(name: "M")])
    }

    @Test("A future schema version is refused with a typed error")
    func futureSchema() throws {
        let error = #expect(throws: SyncCodecError.self) {
            try SyncCodec.decodeBundle(from: json(#"{"schema_version":2,"vocabulary":[{"term":"x"}]}"#))
        }
        #expect(error == .unsupportedSchemaVersion(found: 2, supported: 1))
        #expect(error?.description.contains("Update the app") == true)
    }

    @Test("Schema version zero, negative or missing is refused", arguments: [
        (#"{"schema_version":0}"#, SyncCodecError.unsupportedSchemaVersion(found: 0, supported: 1)),
        (#"{"schema_version":-3}"#, SyncCodecError.unsupportedSchemaVersion(found: -3, supported: 1)),
        (#"{"vocabulary":[]}"#, SyncCodecError.missingSchemaVersion),
        (#"{"schema_version":"1"}"#, SyncCodecError.missingSchemaVersion),
    ])
    func invalidSchemaVersions(input: String, expected: SyncCodecError) {
        #expect(throws: expected) {
            try SyncCodec.decodeBundle(from: json(input))
        }
    }

    @Test("Invalid JSON and non-object roots are reported as invalidJSON", arguments: [
        "", "not json", "[]", "{\"schema_version\":1,", "42",
    ])
    func invalidJSON(input: String) {
        let error = #expect(throws: SyncCodecError.self) {
            try SyncCodec.decodeBundle(from: json(input))
        }
        guard case .invalidJSON = error else {
            Issue.record("Expected invalidJSON, got \(String(describing: error))")
            return
        }
    }

    @Test("Dates accept whole seconds, fractions and offsets; malformed exported_at is nil", arguments: [
        ("2026-11-01T10:00:00Z", Optional(referenceDate)),
        ("2026-11-01T10:00:00.000Z", Optional(referenceDate)),
        ("2026-11-01T11:00:00+01:00", Optional(referenceDate)),
        ("2026-11-01T10:00:00.500Z", Optional(referenceDate.addingTimeInterval(0.5))),
        ("yesterday", nil),
        ("", nil),
    ])
    func exportedAtParsing(input: String, expected: Date?) throws {
        let bundle = try SyncCodec.decodeBundle(from: json(#"{"schema_version":1,"exported_at":"\#(input)"}"#))
        #expect(bundle.exportedAt == expected)
    }

    @Test("Encoding uses the PLAN's snake_case keys and round-trips")
    func roundTrip() throws {
        let bundle = SyncBundle(
            exportedAt: referenceDate,
            source: SyncSource(app: "Hex", appVersion: "3.1.1", via: "settings-file"),
            language: "it",
            vocabulary: [VocabularyEntry(term: "perché", soundsLike: ["perche"])],
            defaultMode: ProcessingMode(
                name: "Global",
                replacements: [Replacement(matchedPhrase: "x", output: "y")],
                transformations: ["lowercase"]
            ),
            modes: [ProcessingMode(name: "Terminal", applications: ["Terminal"], transformations: ["no-trailing-punctuation"])]
        )
        let data = try SyncCodec.encode(bundle)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schema_version", "exported_at", "source", "language", "vocabulary", "default_mode", "modes"])
        #expect(object["exported_at"] as? String == "2026-11-01T10:00:00.000Z")
        let source = try #require(object["source"] as? [String: Any])
        #expect(Set(source.keys) == ["app", "app_version", "via"])
        let mode = try #require(object["default_mode"] as? [String: Any])
        #expect(Set(mode.keys) == ["name", "applications", "browser_hosts", "replacements", "transformations"])
        let replacement = try #require((mode["replacements"] as? [[String: Any]])?.first)
        #expect(Set(replacement.keys) == ["matched_phrase", "output"])
        let entry = try #require((object["vocabulary"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys) == ["term", "sounds_like"])

        #expect(try SyncCodec.decodeBundle(from: data) == bundle)
    }

    @Test("Content comparison ignores exported_at")
    func sameContent() throws {
        let first = try SyncCodec.decodeBundle(from: fixtureData("bundle-v1"))
        var second = first
        second.exportedAt = referenceDate.addingTimeInterval(3600)
        #expect(first.hasSameContent(as: second))
        second.vocabulary.append(VocabularyEntry(term: "New"))
        #expect(!first.hasSameContent(as: second))
    }

    @Test("Active mode: override by name (case-insensitive), else default, else passthrough")
    func activeMode() throws {
        let bundle = try SyncCodec.decodeBundle(from: fixtureData("bundle-v1"))
        #expect(bundle.activeMode().name == "Global")
        #expect(bundle.activeMode(overrideName: " terminal ").name == "Terminal")
        #expect(bundle.activeMode(overrideName: "Missing").name == "Global")
        #expect(bundle.activeMode(overrideName: "").name == "Global")
        #expect(SyncBundle().activeMode(overrideName: "Terminal") == .passthrough)
    }

    @Test("Vocabulary merge unions spellings by case-insensitive term identity")
    func vocabularyMerge() {
        let merged = VocabularyEntry.merged([
            VocabularyEntry(term: "Example Studio", soundsLike: ["example studios"]),
            VocabularyEntry(term: "  ", soundsLike: ["dropped"]),
            VocabularyEntry(term: "Perché", soundsLike: ["perche"]),
            VocabularyEntry(term: "example  studio", soundsLike: ["EXAMPLE STUDIOS", "esempio studio", " "]),
            VocabularyEntry(term: "perche", soundsLike: []),
        ])
        #expect(merged == [
            VocabularyEntry(term: "Example Studio", soundsLike: ["example studios", "esempio studio"]),
            VocabularyEntry(term: "Perché", soundsLike: ["perche"]),
            VocabularyEntry(term: "perche", soundsLike: []),
        ])
    }

    @Test("File names match the PLAN")
    func fileNames() {
        #expect(SyncCodec.bundleFileName == "hex-mobile-sync.json")
        #expect(SyncCodec.pendingVocabularyFileName == "pending-vocabulary.json")
        #expect(SyncCodec.historyExportFileName == "iphone-history.jsonl")
        #expect(SyncCodec.suggestedFolderName == "Hex Mobile")
    }
}

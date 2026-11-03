import Foundation
import Testing
@testable import HexMobileCore

@Suite("Clip library")
struct ClipLibraryTests {
    private func makeAudio(in directory: URL, name: String = UUID().uuidString) throws -> URL {
        let url = directory.appending(path: "\(name).caf")
        try Data("audio".utf8).write(to: url)
        return url
    }

    private func metadata(_ id: String, age: TimeInterval = 0, live: String = "ciao") -> ClipMetadata {
        ClipMetadata(
            id: id,
            createdAt: referenceDate.addingTimeInterval(-age),
            seconds: 3.2,
            locale: "it-IT",
            route: "MicrophoneBuiltIn",
            liveText: live,
            finalPassText: "Ciao.",
            finalPassOutcome: "ok",
            finalPassSeconds: 0.4,
            cleanedText: "Ciao.",
            cleanupOutcome: "ok",
            cleanupSeconds: 0.7,
            insertedText: "Ciao.",
            stopToTextSeconds: 1.2
        )
    }

    @Test("A stored clip moves the audio and keeps the metadata readable")
    func storeMovesAudio() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        let library = ClipLibrary(directory: temp.url.appending(path: "clips"))
        let audio = try makeAudio(in: temp.url)

        try library.store(audio: audio, metadata: metadata("clip-a"))

        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(FileManager.default.fileExists(atPath: library.audioURL(forID: "clip-a").path))
        let listed = library.list()
        #expect(listed.count == 1)
        #expect(listed.first == metadata("clip-a"))
    }

    @Test("Only the newest clips are kept")
    func prunesToLimit() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        let library = ClipLibrary(directory: temp.url.appending(path: "clips"), limit: 3)
        for index in 0..<5 {
            try library.store(audio: try makeAudio(in: temp.url), metadata: metadata("clip-\(index)", age: Double(5 - index)))
        }
        let ids = library.list().map(\.id)
        #expect(ids == ["clip-4", "clip-3", "clip-2"])
        #expect(!FileManager.default.fileExists(atPath: library.audioURL(forID: "clip-0").path))
        #expect(!FileManager.default.fileExists(atPath: library.metadataURL(forID: "clip-0").path))
    }

    @Test("Delete All removes audio and metadata")
    func deleteAll() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        let library = ClipLibrary(directory: temp.url.appending(path: "clips"))
        try library.store(audio: try makeAudio(in: temp.url), metadata: metadata("clip-a"))
        try library.store(audio: try makeAudio(in: temp.url), metadata: metadata("clip-b", age: 5))
        #expect(library.deleteAll() == 2)
        #expect(library.list().isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: library.directory.path)) ?? []
        #expect(left.isEmpty)
    }

    @Test("A half-written pair is cleaned up by prune")
    func prunesOrphans() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        let library = ClipLibrary(directory: temp.url.appending(path: "clips"))
        try library.store(audio: try makeAudio(in: temp.url), metadata: metadata("clip-a"))
        try Data("x".utf8).write(to: library.audioURL(forID: "clip-orphan"))
        #expect(library.prune() == 1)
        #expect(library.list().map(\.id) == ["clip-a"])
        #expect(!FileManager.default.fileExists(atPath: library.audioURL(forID: "clip-orphan").path))
    }

    @Test("The library directory is excluded from backups")
    func excludedFromBackup() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanup() }
        let library = ClipLibrary(directory: temp.url.appending(path: "clips"))
        try library.store(audio: try makeAudio(in: temp.url), metadata: metadata("clip-a"))
        let values = try library.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let audioValues = try library.audioURL(forID: "clip-a").resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(audioValues.isExcludedFromBackup == true)
    }

    @Test("Metadata JSON uses snake_case keys and omits what is absent")
    func jsonShape() throws {
        let minimal = ClipMetadata(id: "clip-a", createdAt: referenceDate, seconds: 1, liveText: "a", insertedText: "A")
        let object = try #require(try JSONSerialization.jsonObject(with: minimal.encoded()) as? [String: Any])
        #expect(object["live_text"] as? String == "a")
        #expect(object["inserted_text"] as? String == "A")
        #expect(object["schema_version"] as? Int == 1)
        #expect(object["cleaned_text"] == nil)
        #expect(object["final_pass_outcome"] == nil)
        #expect(object["final_engine"] == nil)
        #expect(object["whisper_text"] == nil)
        #expect(object["whisper_outcome"] == nil)
        #expect(object["whisper_seconds"] == nil)
    }

    @Test("The Whisper pass is recorded next to Apple's and survives a round trip")
    func whisperFields() throws {
        let clip = ClipMetadata(
            id: "clip-w",
            createdAt: referenceDate,
            seconds: 4,
            liveText: "ciao a tutti",
            finalPassText: "Ciao a tutti.",
            finalPassOutcome: "ok",
            finalPassSeconds: 0.3,
            finalEngine: "whisper",
            whisperText: "Ciao a tutti!",
            whisperOutcome: "ok",
            whisperSeconds: 1.4,
            insertedText: "Ciao a tutti!"
        )
        let data = try clip.encoded()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["final_engine"] as? String == "whisper")
        #expect(object["whisper_text"] as? String == "Ciao a tutti!")
        #expect(object["whisper_outcome"] as? String == "ok")
        #expect(object["whisper_seconds"] as? Double == 1.4)
        // Apple's text keeps its own key.
        #expect(object["final_pass_text"] as? String == "Ciao a tutti.")
        #expect(try ClipMetadata.decode(from: data) == clip)
    }

    @Test("A clip kept before the Whisper engine existed still decodes")
    func decodesOlderClip() throws {
        let json = """
        {"schema_version":1,"id":"clip-old","created_at":"2026-11-01T10:00:00Z","seconds":2,\
        "live_text":"ciao","final_pass_text":"Ciao.","final_pass_outcome":"ok","inserted_text":"Ciao."}
        """
        let clip = try ClipMetadata.decode(from: Data(json.utf8))
        #expect(clip.id == "clip-old")
        #expect(clip.finalPassText == "Ciao.")
        #expect(clip.finalEngine == nil)
        #expect(clip.whisperText == nil)
        #expect(clip.whisperOutcome == nil)
    }

    @Test("An id cannot leave the directory")
    func unsafeID() {
        let library = ClipLibrary(directory: URL(filePath: "/x/clips"))
        #expect(library.audioURL(forID: "../../etc/passwd").path == "/x/clips/etcpasswd.caf")
    }

    @Test("Ids carry the UTC time and sort by it")
    func makeID() {
        #expect(ClipMetadata.makeID(at: referenceDate, suffix: "AB12CD") == "clip-20261101-100000-AB12CD")
    }
}

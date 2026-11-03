#if DEBUG
import Foundation
import HexMobileCore

/// Synthetic content for simulator screenshots (`-HexMobileDemo YES`).
/// Every term and sentence is made up; nothing is written to disk.
@MainActor
enum DemoContent {
    static func load(into services: AppServices) {
        let now = Date()
        let bundle = SyncBundle(
            exportedAt: now,
            source: SyncSource(app: "Hex", appVersion: "0.0.0", via: "cli"),
            language: "en",
            vocabulary: [
                VocabularyEntry(term: "Zentrix", soundsLike: ["zen tricks", "zentrics"]),
                VocabularyEntry(term: "Quillmark", soundsLike: ["quill mark"]),
                VocabularyEntry(term: "Orbisoft", soundsLike: ["orbi soft"]),
            ],
            defaultMode: ProcessingMode(
                name: "Global",
                replacements: [Replacement(matchedPhrase: "new paragraph", output: "\n\n")],
                transformations: []
            ),
            modes: [
                ProcessingMode(name: "Terminal", applications: ["Terminal"], transformations: ["lowercase", "no-trailing-punctuation"]),
                ProcessingMode(name: "Chat", applications: ["Messages"], transformations: ["no-trailing-punctuation"]),
            ]
        )
        var pending = PendingVocabulary()
        pending.add(term: "Lumivox", soundsLike: ["lumi vox"], createdAt: now)
        services.sync.loadDemoContent(bundle: bundle, pending: pending)

        let records = [
            DictationRecord(createdAt: now.addingTimeInterval(-90), text: "Remind me to send the Zentrix draft to the design team before Friday.", duration: 6.2, locale: "en-US", modeName: "Global", engine: "on-device"),
            DictationRecord(createdAt: now.addingTimeInterval(-3_600), text: "The Quillmark build passed on the second try; the flaky test is the date parser.", duration: 8.4, locale: "en-US", modeName: "Global", engine: "on-device"),
            DictationRecord(createdAt: now.addingTimeInterval(-86_400), text: "Domani alle dieci chiamo il fornitore per la consegna.", duration: 4.1, locale: "it-IT", modeName: "Global", engine: "on-device"),
        ]
        services.history.loadDemoRecords(records)
        services.dictation.loadDemoState(lastRecord: records[0])
    }
}
#endif

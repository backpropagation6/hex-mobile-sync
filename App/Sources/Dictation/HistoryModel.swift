import Foundation
import HexMobileCore
import Observation

/// Main-actor view of the on-device dictation history.
@MainActor
@Observable
final class HistoryModel {
    /// Kept records, newest first.
    private(set) var records: [DictationRecord] = []
    /// The last storage error, if any.
    private(set) var lastError: String?

    @ObservationIgnored private let store: HistoryStore

    init(retention: HistoryRetention, fileURL: URL = AppPaths.historyFile) {
        store = HistoryStore(fileURL: fileURL, retention: retention)
    }

    /// Reloads from disk, pruning expired records.
    func reload() async {
        do {
            records = try await store.records()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    func append(_ record: DictationRecord) async {
        do {
            try await store.append(record)
        } catch {
            lastError = String(describing: error)
        }
        await reload()
    }

    func delete(id: UUID) async {
        do {
            try await store.delete(id: id)
        } catch {
            lastError = String(describing: error)
        }
        await reload()
    }

    func deleteAll() async {
        do {
            try await store.deleteAll()
        } catch {
            lastError = String(describing: error)
        }
        await reload()
    }

    func setRetention(_ retention: HistoryRetention) async {
        do {
            try await store.setRetention(retention)
        } catch {
            lastError = String(describing: error)
        }
        await reload()
    }

    /// The history as JSON Lines, for the optional export to the sync folder.
    func jsonLinesExport() -> Data? {
        try? HistoryExport.jsonLines(records)
    }

    #if DEBUG
    /// Synthetic records for screenshots. Never persisted.
    func loadDemoRecords(_ demo: [DictationRecord]) {
        records = demo
    }
    #endif
}

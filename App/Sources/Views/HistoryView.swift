import HexMobileCore
import SwiftUI

/// On-device history: search, copy, share, swipe to delete.
struct HistoryView: View {
    @Environment(HistoryModel.self) private var history
    @Environment(SettingsStore.self) private var settings
    @Environment(SyncManager.self) private var sync

    @State private var query = ""
    @State private var confirmDeleteAll = false
    @State private var copiedID: UUID?

    private var filtered: [DictationRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return history.records }
        return history.records.filter { $0.text.localizedStandardContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    ForEach(filtered) { record in
                        HistoryRow(record: record, isCopied: copiedID == record.id)
                            .contentShape(.rect)
                            .onTapGesture { copy(record) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await delete(record) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    copy(record)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .tint(HexPalette.selection)
                            }
                            .contextMenu {
                                Button("Copy", systemImage: "doc.on.doc") { copy(record) }
                                ShareLink(item: record.text)
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    Task { await delete(record) }
                                }
                            }
                            .accessibilityAction(named: Text("Copy")) { copy(record) }
                    }
                }
                .listRowBackground(HexPalette.card)
            }
            .hexListBackground()
            .listStyle(.insetGrouped)
            .overlay {
                if history.records.isEmpty {
                    Text(RetentionLabel.emptyHistoryDescription(for: settings.historyRetention))
                        .font(.subheadline)
                        .foregroundStyle(HexPalette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .hexCard()
                        .padding(.horizontal)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 8)
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: Text("Search history"))
            .navigationTitle("History")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Delete All", systemImage: "trash", role: .destructive) {
                        confirmDeleteAll = true
                    }
                    .disabled(history.records.isEmpty)
                }
            }
            .confirmationDialog("Delete all dictations?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    Task {
                        await history.deleteAll()
                        await updateSharedExport()
                    }
                }
            } message: {
                Text("This removes the history from this iPhone and from the shared history file. It cannot be undone.")
            }
            .sensoryFeedback(.success, trigger: copiedID)
        }
    }

    private func delete(_ record: DictationRecord) async {
        await history.delete(id: record.id)
        await updateSharedExport()
    }

    /// Keeps `iphone-history.jsonl` in step with deletions: rewritten when
    /// sharing is on, removed when it is off or the history is empty.
    private func updateSharedExport() async {
        guard sync.folderURL != nil else { return }
        if settings.shareHistory, !history.records.isEmpty, let data = history.jsonLinesExport() {
            await sync.exportHistory(data)
        } else {
            await sync.removeHistoryExport()
        }
    }

    private func copy(_ record: DictationRecord) {
        DictationPasteboard.write(record, localOnly: !settings.allowUniversalClipboard)
        copiedID = record.id
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    let isCopied: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.text)
                .lineLimit(4)
                .foregroundStyle(HexPalette.foreground)
            if let raw = record.rawText {
                // What the recognizer heard, before the text rules ran.
                HexChip(text: raw, isPlaceholder: true)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(record.createdAt, format: .relative(presentation: .named))
                if let locale = record.locale {
                    Text(verbatim: "·")
                    Text(locale)
                }
                Spacer()
                if isCopied {
                    Label("Copied", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(HexPalette.foreground)
                }
            }
            .font(.caption)
            .foregroundStyle(HexPalette.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Tap to copy."))
    }
}

/// Localized names for retention periods.
enum RetentionLabel {
    static func emptyHistoryDescription(for retention: HistoryRetention) -> String {
        switch retention {
        case .day: String(localized: "Finished dictations appear here and are kept on this iPhone for one day.")
        case .week: String(localized: "Finished dictations appear here and are kept on this iPhone for one week.")
        case .month: String(localized: "Finished dictations appear here and are kept on this iPhone for one month.")
        case .forever: String(localized: "Finished dictations appear here and are kept on this iPhone until you delete them.")
        }
    }

    static func title(for retention: HistoryRetention) -> String {
        switch retention {
        case .day: String(localized: "1 Day")
        case .week: String(localized: "1 Week")
        case .month: String(localized: "1 Month")
        case .forever: String(localized: "Forever")
        }
    }
}

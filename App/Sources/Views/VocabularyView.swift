import HexMobileCore
import SwiftUI

/// Synced Hex vocabulary (read-only) and terms added on iPhone.
struct VocabularyView: View {
    @Environment(SyncManager.self) private var sync
    @Environment(SettingsStore.self) private var settings

    @State private var isAdding = false
    @State private var query = ""
    @State private var tryInput = ""

    private var filteredSynced: [VocabularyEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sync.syncedVocabulary }
        return sync.syncedVocabulary.filter {
            $0.term.localizedStandardContains(trimmed)
                || $0.soundsLike.contains { $0.localizedStandardContains(trimmed) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    trySection
                    Section {
                        if sync.pending.isEmpty {
                            Text("Names and technical words you add here help recognition and keep their spelling. They are sent to Hex on your Mac at the next sync.")
                                .foregroundStyle(HexPalette.secondary)
                        }
                        ForEach(sync.pending.entries) { entry in
                            TermRow(term: entry.term, soundsLike: entry.soundsLike, badge: Text("Pending"))
                                .swipeActions {
                                    Button(role: .destructive) {
                                        Task { await sync.removePendingTerm(id: entry.id) }
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        HexSectionHeader(title: "Added on iPhone", caption: "Sent at the next sync")
                    } footer: {
                        if sync.folderURL == nil, !sync.pending.isEmpty {
                            Text("Pick the sync folder in Settings to send these terms to your Mac.")
                        }
                    }

                    Section {
                        if sync.syncedVocabulary.isEmpty {
                            Text(sync.bundle == nil
                                 ? "Nothing synced yet. Pick the Hex Mobile folder in Settings."
                                 : "Hex has no vocabulary terms yet.")
                                .foregroundStyle(HexPalette.secondary)
                        }
                        ForEach(filteredSynced, id: \.termKey) { entry in
                            TermRow(term: entry.term, soundsLike: entry.soundsLike, badge: nil)
                        }
                    } header: {
                        HexSectionHeader(title: "From Hex on your Mac", caption: "Read-only")
                    } footer: {
                        if !sync.syncedVocabulary.isEmpty {
                            Text("Read-only. Edit these in Hex on your Mac.")
                        }
                    }
                }
                .listRowBackground(HexPalette.card)
            }
            .hexListBackground()
            .searchable(text: $query, prompt: Text("Search terms"))
            .navigationTitle("Vocabulary")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Term", systemImage: "plus") { isAdding = true }
                }
            }
            .refreshable { await sync.refresh() }
            .sheet(isPresented: $isAdding) {
                AddTermSheet()
            }
        }
    }
}

extension VocabularyView {
    /// Live preview: what Hex pastes for a sentence, with the current rules.
    private var trySection: some View {
        let processor = sync.textProcessor(modeOverride: settings.modeOverride)
        let trimmed = tryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = trimmed.isEmpty ? nil : processor.process(trimmed).text
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Try", text: $tryInput, prompt: Text("Type what you might say"), axis: .vertical)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(HexPalette.inset, in: .rect(cornerRadius: 8))
                Image(systemName: "arrow.down")
                    .font(.footnote.weight(.light))
                    .foregroundStyle(HexPalette.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                HexChip(text: output ?? String(localized: "What Hex pastes"), isPlaceholder: output == nil)
                    .accessibilityLabel(Text("What Hex pastes"))
                    .accessibilityValue(Text(verbatim: output ?? ""))
            }
            .padding(.vertical, 6)
        } header: {
            HexSectionHeader(title: "Try", caption: "What Hex pastes")
        }
    }
}

private struct TermRow: View {
    let term: String
    let soundsLike: [String]
    let badge: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(term).font(.body.weight(.medium))
                Spacer()
                if let badge {
                    badge
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(HexPalette.selection, in: .rect(cornerRadius: 6))
                        .foregroundStyle(HexPalette.secondary)
                }
            }
            ForEach(soundsLike, id: \.self) { phrase in
                HexChip(text: "\(phrase) → \(term)")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AddTermSheet: View {
    @Environment(SyncManager.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @State private var term = ""
    @State private var soundsLike = ""
    @State private var message: String?
    @FocusState private var focusedField: Field?

    private enum Field { case term, soundsLike }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextField("Term", text: $term, prompt: Text("Spelling to produce"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .term)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .soundsLike }
                        TextField("Sounds like", text: $soundsLike, prompt: Text("Comma-separated, optional"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .soundsLike)
                            .submitLabel(.done)
                            .onSubmit(save)
                    } footer: {
                        Text("Used right away on iPhone and added to Hex on your Mac at the next sync. Sounds-like phrases are replaced with the term.")
                    }
                    if let message {
                        Text(message).foregroundStyle(HexPalette.secondary)
                    }
                }
                .listRowBackground(HexPalette.card)
            }
            .hexListBackground()
            .navigationTitle("Add Term")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: save)
                        .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focusedField = .term }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let phrases = soundsLike.split(separator: ",").map { String($0) }
        let newTerm = term
        Task {
            let outcome = await sync.addPendingTerm(newTerm, soundsLike: phrases)
            switch outcome {
            case .added, .merged:
                dismiss()
            case .unchanged:
                message = String(localized: "This term is already pending.")
            case .rejectedBlankTerm:
                message = String(localized: "Enter a term.")
            }
        }
    }
}

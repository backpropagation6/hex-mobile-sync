import HexMobileCore
import SwiftUI

/// Main screen: record, see the live transcript, copy or share the result.
struct DictateView: View {
    @Environment(DictationController.self) private var dictation
    @Environment(SyncManager.self) private var sync
    @Environment(SettingsStore.self) private var settings
    @Environment(SpeechAssetsModel.self) private var assets
    @Environment(AppServices.self) private var services

    @State private var copiedID: UUID?
    #if DEBUG
    @State private var scrollPosition = ScrollPosition(edge: .top)
    #endif
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    transcriptCard
                    // The install card carries the same message for a missing
                    // model (`assetsNotInstalled` sets both), so the banner
                    // would repeat it.
                    if let message = dictation.errorMessage, dictation.missingModelLocale == nil {
                        ErrorBanner(message: message)
                    }
                    if let locale = dictation.missingModelLocale {
                        modelInstallCard(locale: locale)
                    }
                    FlowSessionCard()
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            #if DEBUG
            .scrollPosition($scrollPosition)
            .task {
                // `-HexMobileScroll bottom`, after the content has settled.
                guard LaunchOptions.scrollToBottom else { return }
                try? await Task.sleep(for: .seconds(3))
                scrollPosition.scrollTo(edge: .bottom)
            }
            #endif
            .background(HexPalette.background)
            .safeAreaInset(edge: .bottom) { controls }
            .navigationTitle("Hex Mobile")
            .toolbarTitleDisplayMode(.inlineLarge)
        }
        .sensoryFeedback(trigger: dictation.phase) { old, new in
            switch (old, new) {
            case (_, .recording): .start
            case (.processing, .idle): .success
            default: nil
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusTitle)
                .font(.title2.weight(.semibold))
                .contentTransition(.opacity)
            Text(contextLine)
                .hexCaption()
            // Without terms the recognizers get no hint for names and words of
            // your own; say so, quietly (the same line as long as it is true).
            if let notice = sync.vocabularyNotice {
                Text(VocabularyNoticeLabel.dictate(notice))
                    .font(.footnote)
                    .foregroundStyle(HexPalette.secondary)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: LocalizedStringKey {
        switch dictation.phase {
        case .idle: "Ready"
        case .preparing: "Starting…"
        case .recording: "Listening…"
        case .processing: "Transcribing…"
        }
    }

    private var contextLine: String {
        let language = SpeechModels.displayName(for: services.currentLocale)
        let mode = sync.bundle?.activeMode(overrideName: settings.modeOverride).name
        if let mode {
            return String(localized: "\(language) · Mode: \(mode)")
        }
        return language
    }

    @ViewBuilder private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if dictation.phase == .recording || dictation.phase == .processing {
                Text(liveAttributedText)
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .textSelection(.enabled)
                    .accessibilityLabel(Text(dictation.liveText.isEmpty ? String(localized: "Listening") : dictation.liveText))
            } else if let record = dictation.lastRecord {
                Text(record.text)
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .textSelection(.enabled)
                resultActions(for: record)
            } else {
                Text("Nothing dictated yet. Tap the hexagon and start speaking, or hold it to talk.")
                    .font(.subheadline)
                    .foregroundStyle(HexPalette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            }
        }
        .padding(18)
        .hexCard()
    }

    private var liveAttributedText: AttributedString {
        if dictation.liveText.isEmpty {
            var placeholder = AttributedString(String(localized: "Speak now…"))
            placeholder.foregroundColor = HexPalette.secondary
            return placeholder
        }
        var finalized = AttributedString(dictation.liveFinalized)
        var volatile = AttributedString(
            dictation.liveFinalized.isEmpty || dictation.liveVolatile.isEmpty
                ? dictation.liveVolatile
                : " " + dictation.liveVolatile
        )
        finalized.foregroundColor = HexPalette.foreground
        volatile.foregroundColor = HexPalette.secondary
        return finalized + volatile
    }

    private func resultActions(for record: DictationRecord) -> some View {
        HStack(spacing: 12) {
            Button {
                DictationPasteboard.write(record, localOnly: !settings.allowUniversalClipboard)
                copiedID = record.id
            } label: {
                Label(copiedID == record.id ? "Copied" : "Copy",
                      systemImage: copiedID == record.id ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.hexFilled)
            .sensoryFeedback(.success, trigger: copiedID)

            ShareLink(item: record.text) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.hex)

            Spacer()

            if let duration = record.duration {
                Text(Duration.seconds(duration), format: .units(allowed: [.minutes, .seconds], width: .narrow))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(HexPalette.secondary)
            }
        }
    }

    private func modelInstallCard(locale: Locale) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Speech model needed", systemImage: "arrow.down.circle")
                .font(.headline)
            Text("Download the on-device model for \(SpeechModels.displayName(for: locale)) once. After that, dictation works offline.")
                .font(.subheadline)
                .foregroundStyle(HexPalette.secondary)
            if assets.isInstalling {
                ProgressView(value: assets.progress)
                    .accessibilityLabel(Text("Downloading speech model"))
            } else {
                Button("Download Model") {
                    Task { await assets.install(for: locale) }
                }
                .buttonStyle(.hexFilled)
            }
            if let error = assets.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hexCard()
    }

    private var controls: some View {
        VStack(spacing: 4) {
            RecordButton(
                phase: dictation.phase,
                level: dictation.level,
                onTap: { Task { await dictation.toggle() } },
                onHoldStart: { Task { await dictation.start() } },
                onHoldEnd: { Task { await dictation.stop() } },
                diameter: isCompactHeight ? 64 : 120
            )
            Text(controlHint)
                .font(.footnote)
                .foregroundStyle(HexPalette.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
        .background(HexPalette.background)
    }

    private var controlHint: LocalizedStringKey {
        switch dictation.phase {
        case .recording: "Tap to stop"
        case .idle: "Tap to start · Hold to talk"
        case .preparing, .processing: "Please wait…"
        }
    }
}

/// A red banner for user-facing errors.
struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.subheadline)
        .foregroundStyle(.red)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1), in: .rect(cornerRadius: 16))
    }
}

/// Start or end the flow session used by the keyboard.
struct FlowSessionCard: View {
    @Environment(DictationController.self) private var dictation
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Flow session", systemImage: "keyboard")
                    .font(.body.weight(.medium))
                Spacer()
                if dictation.isFlowSessionActive {
                    Text("Active")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(HexPalette.foreground, in: .capsule)
                        .foregroundStyle(HexPalette.onForeground)
                }
            }
            Text(description)
                .font(.subheadline)
                .foregroundStyle(HexPalette.secondary)
            Button {
                Task {
                    if dictation.isFlowSessionActive {
                        await dictation.endFlowSession()
                    } else {
                        await dictation.startFlowSession()
                    }
                }
            } label: {
                Text(dictation.isFlowSessionActive ? "End Flow Session" : "Start Flow Session")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.hex)
        }
        .padding(18)
        .hexCard()
    }

    private var description: String {
        if dictation.isFlowSessionActive, let end = dictation.flowSessionEndsAt {
            return String(localized: "The Hex Mobile keyboard can dictate in any app. Ends at \(end.formatted(date: .omitted, time: .shortened)) if unused.")
        }
        if dictation.flowSessionNeverEnds {
            return String(localized: "The Hex Mobile keyboard can dictate in any app. Stays on until you end it.")
        }
        guard let minutes = settings.flowSessionDuration.minutes else {
            return String(localized: "Keeps the microphone ready in the background so the Hex Mobile keyboard can dictate in any app. Stays on until you end it.")
        }
        return String(localized: "Keeps the microphone ready in the background so the Hex Mobile keyboard can dictate in any app. Ends after \(minutes) idle minutes.")
    }
}

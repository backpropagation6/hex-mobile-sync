import SwiftUI

/// The screen the `hexmobile://dictate` route opens (the microphone key of the
/// keyboard without a flow session): the dictation is already running, and
/// the only thing left to do is to go back to the previous app. iOS gives
/// the app no way to switch back by itself, so the screen says how: the
/// button at the top left that iOS shows after one app opens another, or a swipe
/// right along the bottom edge. The dictation does not stop if the user stays.
struct KeyboardDictationView: View {
    @Environment(DictationController.self) private var dictation
    @Environment(AppServices.self) private var services
    @Environment(\.scenePhase) private var scenePhase

    /// A recording or a transcription was seen: an idle controller after that
    /// means the dictation ended, and the screen goes away.
    @State private var sawDictation = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            if let message = failure {
                errorContent(message)
            } else {
                dictationContent
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HexPalette.background)
        .onChange(of: dictation.phase, initial: true) { _, phase in
            if phase == .recording || phase == .processing { sawDictation = true }
            dismissIfFinished()
        }
        .onChange(of: scenePhase) { _, _ in dismissIfFinished() }
    }

    /// The reason the dictation did not start, if it did not.
    private var failure: String? {
        guard dictation.phase == .idle, !dictation.isFlowSessionStarting,
              !dictation.lastStopFoundNoSpeech else { return nil }
        return dictation.errorMessage
    }

    // MARK: - Content

    private var dictationContent: some View {
        VStack(spacing: 20) {
            ParticleBlob(state: markState, level: dictation.level, count: 900)
                .frame(width: 220, height: 220)
            Text(title)
                .font(.title2.weight(.semibold))
                .contentTransition(.opacity)
            if dictation.phase == .recording, !dictation.liveText.isEmpty {
                Text(String(dictation.liveText.suffix(160)))
                    .font(.body)
                    .foregroundStyle(HexPalette.secondary)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .multilineTextAlignment(.center)
            }
            Text("Go back to your app: tap the button at the top left, or swipe right along the bottom edge. Dictation keeps running.")
                .font(.subheadline)
                .foregroundStyle(HexPalette.foreground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(sawDictation ? "Dictation failed" : "Dictation could not start")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(HexPalette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var actions: some View {
        if failure != nil {
            HStack(spacing: 12) {
                Button("Close") { close() }
                    .buttonStyle(.hex)
                Button("Retry") {
                    Task { await services.dictateFromRoute(source: "retry") }
                }
                .buttonStyle(.hexFilled)
            }
        } else {
            HStack(spacing: 12) {
                Button {
                    Diagnostics.record("route dictate view cancel phase=\(dictation.phase)")
                    Task { await dictation.cancel() }
                    close()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(.hex)
                Button {
                    Diagnostics.record("route dictate view done phase=\(dictation.phase)")
                    Task { await dictation.stop() }
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.hexFilled)
                .disabled(dictation.phase != .recording)
            }
        }
    }

    // MARK: - State

    private var title: LocalizedStringKey {
        switch dictation.phase {
        case .idle, .preparing: "Starting…"
        case .recording: "Listening…"
        case .processing: "Transcribing…"
        }
    }

    private var markState: HexMarkState {
        switch dictation.phase {
        case .recording: .recording
        case .processing: .processing
        case .idle, .preparing: .idle
        }
    }

    private func close() {
        // The keyboard's own copy of the message goes with this one.
        dictation.clearKeyboardFailure()
        services.keyboardDictationShown = false
    }

    /// Dictation over (stopped here, from the keyboard or from the island):
    /// the screen has nothing left to say. An error stays until Close; an empty
    /// transcript is not one (the Action Button ends quietly then too).
    private func dismissIfFinished() {
        guard sawDictation, dictation.phase == .idle, failure == nil else { return }
        close()
    }
}

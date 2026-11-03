import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Lock Screen and Dynamic Island UI for recording and flow sessions.
struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            LockScreenView(state: context.state, isFlowSession: context.attributes.isFlowSession)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: context.state.phase)
                        .frame(width: 32, height: 32)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedTime(state: context.state)
                        .font(.title3.monospacedDigit())
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(PhaseText.title(for: context.state.phase, refining: context.state.refining == true))
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                    LiveTranscript(text: context.state.liveText, lines: 2, keepsStart: context.state.phase == .handoff)
                    HandoffHint(phase: context.state.phase)
                    NeverEndsHint(state: context.state)
                    HStack(spacing: 12) {
                        DotWavePill(state: markState(context.state.phase), animated: false)
                            .frame(height: 34)
                        StopButton(phase: context.state.phase, isFlowSession: context.attributes.isFlowSession)
                            .fixedSize()
                    }
                    }
                }
            } compactLeading: {
                DotMatrixWave(state: markState(context.state.phase), columns: 9, rows: 7,
                              animated: false, seed: waveSeed(context.state), compact: true,
                              compactLevel: context.state.level, compactSide: .leading)
                    .frame(width: 44, height: 24)
            } compactTrailing: {
                DotMatrixWave(state: markState(context.state.phase), columns: 9, rows: 7,
                              animated: false, seed: waveSeed(context.state), compact: true,
                              compactLevel: context.state.level, compactSide: .trailing)
                    .frame(width: 44, height: 24)
            } minimal: {
                DotMatrixWave(state: markState(context.state.phase), columns: 5, rows: 5,
                              animated: false, seed: waveSeed(context.state), compact: true)
                    .frame(width: 18, height: 16)
            }
            .keylineTint(.white)
        }
    }
}

private struct LockScreenView: View {
    let state: DictationActivityAttributes.ContentState
    let isFlowSession: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
        DotWavePill(state: markState(state.phase), animated: false)
            .frame(height: 40)
        LiveTranscript(text: state.liveText, lines: 3, keepsStart: state.phase == .handoff)
        HandoffHint(phase: state.phase)
        HStack(spacing: 14) {
            PhaseIcon(phase: state.phase)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(PhaseText.title(for: state.phase, refining: state.refining == true))
                    .font(.headline)
                    .foregroundStyle(.white)
                // The handoff hint is a full-width line above: beside the
                // stop button it would be cut after two short lines.
                if state.phase != .handoff {
                    Text(PhaseText.subtitle(for: state.phase, isFlowSession: isFlowSession, neverEnds: state.neverEnds == true))
                        .font(.caption.monospaced().smallCaps())
                        .foregroundStyle(Color(hex: 0x9A9A9A))
                }
            }
            Spacer(minLength: 8)
            ElapsedTime(state: state)
                .font(.title3.monospacedDigit())
                .foregroundStyle(.white)
            StopButton(phase: state.phase, isFlowSession: isFlowSession)
                .fixedSize()
        }
        }
        .padding()
    }
}

/// The concentric hexagon mark, white on black, with the red recording dot.
private struct PhaseIcon: View {
    let phase: DictationActivityAttributes.ContentState.Phase

    var body: some View {
        ConcentricHexagons(state: markState, animated: false, color: .white)
            .overlay(alignment: .topTrailing) {
                if phase == .recording {
                    RecordingDot(size: 6)
                }
            }
            .accessibilityHidden(true)
    }

    private var markState: HexMarkState {
        switch phase {
        case .ready, .standby, .handoff: .idle
        case .recording: .recording
        case .processing: .processing
        }
    }
}

private struct ElapsedTime: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        if state.phase == .recording, let start = state.recordingStartedAt {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        } else if state.phase == .ready, state.neverEnds == true {
            // Nothing is counting down: the session has no idle timeout.
            Image(systemName: "infinity")
                .accessibilityLabel(Text(PhaseText.neverEnds))
        }
    }
}

private struct StopButton: View {
    let phase: DictationActivityAttributes.ContentState.Phase
    let isFlowSession: Bool

    var body: some View {
        Button(intent: StopDictationIntent()) {
            Label(phase == .recording ? "Stop" : (isFlowSession ? "End Session" : "Stop"),
                  systemImage: "stop.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.black)
        }
        .tint(.white)
        .disabled(phase == .processing)
    }
}

private enum PhaseText {
    static func title(for phase: DictationActivityAttributes.ContentState.Phase, refining: Bool = false) -> LocalizedStringResource {
        switch phase {
        case .ready: "Ready to dictate"
        case .standby: "Hex Mobile"
        case .recording: "Recording"
        case .processing: refining ? "Fixing the text…" : "Transcribing…"
        case .handoff: "Text ready"
        }
    }

    /// What the activity says when the session has no idle timeout.
    static let neverEnds: LocalizedStringResource = "Stays on until you end it"

    static func subtitle(for phase: DictationActivityAttributes.ContentState.Phase, isFlowSession: Bool, neverEnds: Bool = false) -> LocalizedStringResource {
        switch phase {
        case .ready: neverEnds ? Self.neverEnds : "Use the Hex Mobile keyboard"
        case .standby: "Press the Action Button to dictate"
        case .recording: isFlowSession ? (neverEnds ? Self.neverEnds : "Flow session") : "Hex Mobile"
        case .processing: "On this iPhone"
        case .handoff: "Open the Hex Mobile keyboard to insert it"
        }
    }
}

private func markState(_ phase: DictationActivityAttributes.ContentState.Phase) -> HexMarkState {
    switch phase {
    case .ready, .standby, .handoff: .idle
    case .recording: .recording
    case .processing: .processing
    }
}

/// The tail of the live transcript, newest words visible; with `keepsStart`
/// (a finished text waiting for the keyboard) its start, cut at the end.
private struct LiveTranscript: View {
    let text: String?
    let lines: Int
    var keepsStart = false

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.callout)
                .foregroundStyle(.white)
                .lineLimit(lines)
                .truncationMode(keepsStart ? .tail : .head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Asks to open the keyboard while a finished text waits for it.
private struct HandoffHint: View {
    let phase: DictationActivityAttributes.ContentState.Phase

    var body: some View {
        if phase == .handoff {
            Text(PhaseText.subtitle(for: phase, isFlowSession: true))
                .font(.caption)
                .foregroundStyle(Color(hex: 0x9A9A9A))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// In the expanded island: the session has no idle timeout (Settings > End
/// After Idle > Never), so it stays on until the user ends it.
private struct NeverEndsHint: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        if state.neverEnds == true, state.phase == .ready || state.phase == .recording {
            Label {
                Text(PhaseText.neverEnds)
            } icon: {
                Image(systemName: "infinity")
            }
            .font(.caption)
            .foregroundStyle(Color(hex: 0x9A9A9A))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Changes with every live transcript update, so the static wave shifts
/// shape while you speak.
private func waveSeed(_ state: DictationActivityAttributes.ContentState) -> Double {
    Double(state.liveText?.count ?? 0) * 0.37 + (state.level ?? 0) * 11
}

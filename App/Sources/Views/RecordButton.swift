import SwiftUI

/// The hexagon record control: tap to start or stop, hold to talk. The
/// concentric rings follow the microphone level while recording.
struct RecordButton: View {
    let phase: DictationController.Phase
    let level: Float
    /// Tap: toggle dictation.
    let onTap: () -> Void
    /// Hold started while idle: start push-to-talk.
    let onHoldStart: () -> Void
    /// Hold released after push-to-talk started: stop.
    let onHoldEnd: () -> Void
    /// Button size; smaller in compact height (landscape).
    var diameter: CGFloat = 120

    @State private var isPressed = false
    @State private var isHolding = false
    @State private var holdTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let holdDelay: Duration = .milliseconds(350)

    var body: some View {
        ZStack {
            ParticleBlob(state: markState, level: level, count: 900)
                .frame(width: diameter * 1.55, height: diameter * 1.55)
                .scaleEffect(isPressed ? 0.94 : 1)
                .animation(reduceMotion ? nil : .spring(duration: 0.25), value: isPressed)


            if phase == .recording {
                RecordingDot(size: max(6, diameter * 0.07))
                    .offset(y: -diameter * 0.8)
            }
        }
        .frame(width: diameter * 1.6, height: diameter * 1.6)
        .contentShape(Circle())
        .gesture(pressGesture)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Text("Double-tap to start or stop dictation."))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
        // Tapping while preparing abandons the start (see
        // `DictationController.toggle`), so only processing is locked.
        .disabled(phase == .processing)
    }

    @ViewBuilder private var icon: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .recording:
            Image(systemName: "stop.fill")
        case .preparing, .processing:
            EmptyView()
        }
    }

    private var markState: HexMarkState {
        switch phase {
        case .idle: .idle
        case .recording: .recording
        case .preparing, .processing: .processing
        }
    }

    private var accessibilityLabel: Text {
        switch phase {
        case .idle: Text("Start dictation")
        case .preparing: Text("Preparing")
        case .recording: Text("Stop dictation")
        case .processing: Text("Transcribing")
        }
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                isPressed = true
                guard phase == .idle else { return }
                holdTask = Task { @MainActor in
                    try? await Task.sleep(for: Self.holdDelay)
                    guard !Task.isCancelled, isPressed, phase == .idle else { return }
                    isHolding = true
                    onHoldStart()
                }
            }
            .onEnded { _ in
                isPressed = false
                holdTask?.cancel()
                holdTask = nil
                if isHolding {
                    isHolding = false
                    onHoldEnd()
                } else {
                    onTap()
                }
            }
    }
}

/// A row of bars that follows the microphone level.
struct LevelMeter: View {
    let level: Float
    let isActive: Bool

    @State private var samples: [Float] = Array(repeating: 0, count: 28)

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(samples.indices, id: \.self) { index in
                Capsule()
                    .fill(isActive ? HexPalette.foreground.opacity(0.85) : HexPalette.separator)
                    .frame(width: 4, height: 4 + CGFloat(samples[index]) * 36)
            }
        }
        .frame(height: 40)
        .animation(.linear(duration: 0.05), value: samples)
        .onChange(of: level) { _, newValue in
            samples.removeFirst()
            samples.append(isActive ? newValue : 0)
        }
        .onChange(of: isActive) { _, active in
            if !active { samples = Array(repeating: 0, count: samples.count) }
        }
        .accessibilityHidden(true)
    }
}

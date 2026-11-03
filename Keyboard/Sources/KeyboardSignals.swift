import HexMobileCore

/// The keyboard's Darwin notifications: one stream for the whole process,
/// handed to the model of the keyboard that appeared last.
///
/// Each model used to open its own stream in `appear()` and close it in
/// `disappear()`. iOS does not always send `viewDidDisappear` before it drops
/// a keyboard (device log of 1 Nov 2026: `appear` with no `disappear` before
/// the next controller), so the models of the dropped keyboards stayed
/// subscribed and every signal arrived once per model. A relay has no
/// teardown to forget: one observation for the process, a weak subscriber.
@MainActor
enum KeyboardSignals {
    private static let signals: [HexMobileIPC.Signal] = [
        .pong, .stateIdle, .stateRecording, .stateProcessing, .done, .sessionEnded, .startFailed,
    ]

    /// Opened on first use (the first `appear`), before the first `ping`.
    private static let relay = SignalRelay<HexMobileIPC.Signal, KeyboardModel>(
        stream: DarwinNotificationCenter.shared.signals(signals)
    ) { model, signal in
        model.handle(signal)
    }

    /// From now on `model` receives the signals.
    static func attach(_ model: KeyboardModel) {
        relay.attach(model)
        #if DEBUG
        debugKeys.attach(model)
        #endif
    }

    /// `model` stops receiving, if it was the one that did.
    static func detach(_ model: KeyboardModel) {
        relay.detach(model)
        #if DEBUG
        debugKeys.detach(model)
        #endif
    }

    #if DEBUG
    /// Debug builds only: `xcrun simctl spawn <udid> notifyutil -p
    /// io.github.hexmobile.debug.keyboard.close|retry` presses the Close and
    /// Retry keys of the error message, which a headless simulator cannot tap.
    private static let debugKeys = SignalRelay<String, KeyboardModel>(
        stream: DarwinNotificationCenter.shared.notifications(named: [
            "io.github.hexmobile.debug.keyboard.close",
            "io.github.hexmobile.debug.keyboard.retry",
        ])
    ) { model, name in
        if name.hasSuffix("close") { model.closeFailureTapped() } else { model.retryTapped() }
    }
    #endif
}

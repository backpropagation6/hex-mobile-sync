import AppIntents
import Foundation
import HexMobileCore

// These intents are compiled into the app and into the widget extension:
// the Live Activity stop button and the Control Center control need the type
// at compile time, while the work happens in the app. On iOS 27 and later
// `allowedExecutionTargets` pins both intents to the app process. On iOS 26
// the system runs `AudioRecordingIntent` and `LiveActivityIntent` in the app
// process when the app contains the intent; the `#else` branches are a
// fallback for the widget extension: the stop request is forwarded to a
// running app over a Darwin notification, and a toggle fails with a message,
// because it could neither record nor return the text from there.

/// Starts dictation, or stops it, transcribes on device and returns the text.
///
/// Bound to the Action Button, Shortcuts and the Control Center control.
// Also a `LiveActivityIntent`: as a plain `AudioRecordingIntent`, run from
// the Action Button while another app is in front, ActivityKit refused the
// Live Activity with `ActivityAuthorizationError.visibility` (1 Nov 2026,
// iOS 27.2). A `LiveActivityIntent` may start one from the background.
struct ToggleDictationIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Toggle Dictation" }
    static var description: IntentDescription? {
        IntentDescription("Starts dictation. Run it again to stop, transcribe on this iPhone and copy the text. The microphone then turns off as soon as the Hex Mobile keyboard has taken the text, after a minute at most, unless a flow session was already running.")
    }
    /// Background only: with `.foreground(.dynamic)` iOS sometimes opened
    /// the app on an Action Button press (1 Nov 2026). Since the intent is a
    /// `LiveActivityIntent`, the Live Activity starts from the background.
    static var supportedModes: IntentModes { .background }

    @available(iOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        #if HEXMOBILE_APP
        let text = try await IntentBridge.toggleDictation()
        return .result(value: text)
        #else
        // Outside the app process: neither recording nor returning the text
        // is possible, so fail with a message (the value is never returned).
        try ExtensionIntentError.requireApp()
        return .result(value: "")
        #endif
    }
}

/// Stop button of the Live Activity: finishes the current dictation, or ends
/// the flow session when nothing is being recorded.
struct StopDictationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Stop Dictation" }
    static var description: IntentDescription? {
        IntentDescription("Stops the current dictation or ends the flow session.")
    }
    static var isDiscoverable: Bool { false }
    static var supportedModes: IntentModes { .background }

    @available(iOS 27, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    init() {}

    func perform() async throws -> some IntentResult {
        #if HEXMOBILE_APP
        await IntentBridge.stopFromLiveActivity()
        #else
        DarwinNotificationCenter.shared.post(SharedSignal.stop)
        #endif
        return .result()
    }
}

/// Darwin notification names used only between the app and its widget
/// extension (the keyboard protocol lives in `HexMobileIPC`).
enum SharedSignal {
    /// Widget → app: stop recording, or end the flow session when idle.
    static let stop = HexMobileIPC.notificationPrefix + ".stop"
}

#if !HEXMOBILE_APP
/// Shown when the system runs an intent outside the app process.
enum ExtensionIntentError: LocalizedError {
    case appRequired

    /// Always throws ``appRequired``.
    static func requireApp() throws {
        throw appRequired
    }

    var errorDescription: String? {
        String(localized: "Open Hex Mobile once, then try again. Dictation runs in the app.")
    }
}
#endif

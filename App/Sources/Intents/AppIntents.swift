import AppIntents
import Foundation

/// Starts a flow session: the microphone stays ready in the background so
/// the Hex Mobile keyboard can dictate into any app.
struct StartFlowSessionIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Start Flow Session" }
    static var description: IntentDescription? {
        IntentDescription("Keeps the microphone ready so the Hex Mobile keyboard can dictate in any app. Ends after the idle time set in the app.")
    }
    static var supportedModes: IntentModes { .background }

    init() {}

    func perform() async throws -> some IntentResult {
        try await IntentBridge.startFlowSession()
        return .result()
    }
}

/// Shortcuts and Siri phrases.
struct HexMobileShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleDictationIntent(),
            phrases: [
                "Dictate with \(.applicationName)",
                "Toggle \(.applicationName) dictation",
            ],
            shortTitle: "Dictate",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StartFlowSessionIntent(),
            phrases: [
                "Start a \(.applicationName) flow session",
            ],
            shortTitle: "Flow Session",
            systemImageName: "keyboard"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .grayBlue }
}

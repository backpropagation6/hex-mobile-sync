import Foundation
import HexMobileCore
import Observation

/// The engine behind "Final Text Engine" in Settings.
enum FinalTextEngine: String, CaseIterable, Sendable {
    /// `SpeechTranscriber` without the fast option (the default).
    case apple
    /// WhisperKit with the large-v3 turbo model, after the Apple pass.
    case whisper
}

/// User preferences, persisted in the app's own `UserDefaults`.
///
/// The keyboard extension cannot read these (no App Group by design); every
/// setting here applies to the app only.
@MainActor
@Observable
final class SettingsStore {
    private enum Key {
        static let languageIdentifier = "settings.languageIdentifier"
        static let modeOverride = "settings.modeOverride"
        static let copyToClipboard = "settings.copyToClipboard"
        static let allowUniversalClipboard = "settings.allowUniversalClipboard"
        static let historyRetention = "settings.historyRetention"
        static let shareHistory = "settings.shareHistory"
        static let flowSessionMinutes = "settings.flowSessionMinutes"
        static let lightAppearance = "settings.lightAppearance"
        static let cleanupEnabled = "settings.cleanupEnabled"
        static let keepAudioClips = "settings.keepAudioClips"
        static let finalTextEngine = "settings.finalTextEngine"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Recognition language chosen by the user; `nil` follows the synced
    /// language, then the device language.
    var languageIdentifier: String? {
        didSet { defaults.set(languageIdentifier, forKey: Key.languageIdentifier) }
    }

    /// Name of the synced mode to use instead of the default mode.
    var modeOverride: String? {
        didSet { defaults.set(modeOverride, forKey: Key.modeOverride) }
    }

    /// Copy each finished dictation to the clipboard.
    var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Key.copyToClipboard) }
    }

    /// Let copies reach the user's other Apple devices through Universal
    /// Clipboard. Off by default: copies stay on this iPhone.
    var allowUniversalClipboard: Bool {
        didSet { defaults.set(allowUniversalClipboard, forKey: Key.allowUniversalClipboard) }
    }

    /// How long dictations stay in the on-device history.
    var historyRetention: HistoryRetention {
        didSet { defaults.set(historyRetention.rawValue, forKey: Key.historyRetention) }
    }

    /// Export the history to `iphone-history.jsonl` in the sync folder.
    var shareHistory: Bool {
        didSet { defaults.set(shareHistory, forKey: Key.shareHistory) }
    }

    /// How long a flow session stays up with nothing to do: 5, 15 or 60
    /// minutes, or never. Stored as minutes (0 for never) under the key the
    /// old 1 to 30 minute stepper used; an old value reads as the next choice
    /// up (``FlowSessionDuration/init(storedMinutes:)``).
    var flowSessionDuration: FlowSessionDuration {
        didSet { defaults.set(flowSessionDuration.rawValue, forKey: Key.flowSessionMinutes) }
    }

    /// Fix the dictated text with the on-device language model (punctuation,
    /// capitals, hesitations). On by default; it only acts when the model is
    /// available, and the recognizer's text stands whenever it is not.
    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled) }
    }

    /// Keep the audio and texts of the last dictations in the app (never
    /// synced, excluded from backups) to compare recognizers on a Mac. Off by
    /// default: it is the user's choice.
    var keepAudioClips: Bool {
        didSet { defaults.set(keepAudioClips, forKey: Key.keepAudioClips) }
    }

    /// Which engine reads the recording after the stop. Apple's pass always
    /// runs; Whisper is a second pass after it, and only when the model is on
    /// the iPhone and loaded in time (see `DictationController.accurateText`).
    var finalTextEngine: FinalTextEngine {
        didSet { defaults.set(finalTextEngine.rawValue, forKey: Key.finalTextEngine) }
    }

    /// Use the light (still monochrome) appearance. Dark is the default.
    var lightAppearance: Bool {
        didSet { defaults.set(lightAppearance, forKey: Key.lightAppearance) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        languageIdentifier = defaults.string(forKey: Key.languageIdentifier)
        modeOverride = defaults.string(forKey: Key.modeOverride)
        copyToClipboard = defaults.object(forKey: Key.copyToClipboard) as? Bool ?? true
        allowUniversalClipboard = defaults.bool(forKey: Key.allowUniversalClipboard)
        historyRetention = defaults.string(forKey: Key.historyRetention)
            .flatMap(HistoryRetention.init(rawValue:)) ?? .default
        shareHistory = defaults.object(forKey: Key.shareHistory) as? Bool ?? false
        lightAppearance = defaults.bool(forKey: Key.lightAppearance)
        cleanupEnabled = defaults.object(forKey: Key.cleanupEnabled) as? Bool ?? true
        keepAudioClips = defaults.bool(forKey: Key.keepAudioClips)
        finalTextEngine = defaults.string(forKey: Key.finalTextEngine)
            .flatMap(FinalTextEngine.init(rawValue:)) ?? .apple
        flowSessionDuration = (defaults.object(forKey: Key.flowSessionMinutes) as? Int)
            .map(FlowSessionDuration.init(storedMinutes:)) ?? .default
    }

    /// The locale to recognize: the user's choice, else the synced Hex
    /// language, else the device language.
    func recognitionLocale(syncedLanguage: String?) -> Locale {
        if let languageIdentifier, !languageIdentifier.isEmpty {
            return Locale(identifier: languageIdentifier)
        }
        if let syncedLanguage = syncedLanguage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !syncedLanguage.isEmpty, syncedLanguage.lowercased() != "auto" {
            return Locale(identifier: syncedLanguage)
        }
        return Locale.current
    }
}

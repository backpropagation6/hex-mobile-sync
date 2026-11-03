import Foundation
import Observation

/// Model install state for Settings and the Dictate screen.
@MainActor
@Observable
final class SpeechAssetsModel {
    private(set) var locale: Locale?
    private(set) var resolvedLocale: Locale?
    private(set) var moduleKind: SpeechModuleKind?
    private(set) var state: SpeechAssetState?
    private(set) var isInstalling = false
    private(set) var progress: Double = 0
    private(set) var errorMessage: String?
    private(set) var availableLocales: [Locale] = []

    /// Called with the locale whenever a refresh finds its model installed:
    /// after an install, in the foreground, or on opening Settings. The
    /// Dictate screen uses it to drop its install card (see ``AppServices``).
    @ObservationIgnored var onInstalled: (@MainActor (Locale) -> Void)?

    /// Updates the state for `locale`.
    func refresh(for locale: Locale) async {
        self.locale = locale
        let result = await SpeechModels.assetState(for: locale)
        guard self.locale == locale else { return }
        state = result.state
        resolvedLocale = result.resolved?.locale
        moduleKind = result.resolved?.kind
        if result.state == .installed { onInstalled?(locale) }
    }

    /// Loads the locales offered in the language picker.
    func loadAvailableLocales() async {
        guard availableLocales.isEmpty else { return }
        availableLocales = await SpeechModels.supportedLocales()
    }

    /// Downloads and installs the model for `locale`.
    func install(for locale: Locale) async {
        guard !isInstalling else { return }
        isInstalling = true
        progress = 0
        errorMessage = nil
        do {
            try await SpeechModels.install(for: locale) { [weak self] value in
                self?.progress = value
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isInstalling = false
        await refresh(for: locale)
    }
}

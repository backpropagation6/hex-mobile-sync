import Foundation
import Speech

/// Which Speech module handles a locale.
enum SpeechModuleKind: String, Sendable {
    /// `SpeechTranscriber`: the newer general-purpose model.
    case speechTranscriber
    /// `DictationTranscriber`: the keyboard dictation model, wider locale coverage.
    case dictationTranscriber
}

/// A Speech module configured for a locale.
struct ResolvedSpeechModule: Sendable {
    var kind: SpeechModuleKind
    var locale: Locale
    var module: any SpeechModule
}

/// Install state of the on-device model for a locale.
enum SpeechAssetState: Equatable, Sendable {
    case unsupportedLocale
    case notInstalled
    case downloading
    case installed
}

/// Locale resolution and model assets for the on-device engine.
enum SpeechModels {
    /// Picks `SpeechTranscriber` when the device and locale support it,
    /// otherwise `DictationTranscriber`. Returns `nil` when neither supports
    /// the locale.
    static func resolve(for locale: Locale) async -> ResolvedSpeechModule? {
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(
                locale: supported,
                transcriptionOptions: [],
                // `fastResults`: the first live words in about a second
                // instead of ~10 s (1 Nov 2026, only one update per short
                // dictation without it), as in Apple's progressive preset.
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: []
            )
            return ResolvedSpeechModule(kind: .speechTranscriber, locale: supported, module: transcriber)
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(
                locale: supported,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: []
            )
            return ResolvedSpeechModule(kind: .dictationTranscriber, locale: supported, module: transcriber)
        }
        return nil
    }

    /// Locales offered in Settings: the union of both modules, sorted by
    /// display name in the current language.
    static func supportedLocales() async -> [Locale] {
        var byIdentifier: [String: Locale] = [:]
        if SpeechTranscriber.isAvailable {
            for locale in await SpeechTranscriber.supportedLocales {
                byIdentifier[locale.identifier(.bcp47)] = locale
            }
        }
        for locale in await DictationTranscriber.supportedLocales {
            byIdentifier[locale.identifier(.bcp47), default: locale] = locale
        }
        return byIdentifier.values.sorted {
            displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    /// The model state for a locale.
    static func assetState(for locale: Locale) async -> (state: SpeechAssetState, resolved: ResolvedSpeechModule?) {
        guard let resolved = await resolve(for: locale) else { return (.unsupportedLocale, nil) }
        let status = await AssetInventory.status(forModules: [resolved.module])
        let state: SpeechAssetState = switch status {
        case .installed: .installed
        case .downloading: .downloading
        case .supported: .notInstalled
        case .unsupported: .unsupportedLocale
        @unknown default: .notInstalled
        }
        return (state, resolved)
    }

    /// Downloads and installs the model for a locale, reporting progress in
    /// 0...1 on the main actor.
    static func install(
        for locale: Locale,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        guard let resolved = await resolve(for: locale) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier(.bcp47))
        }
        // Reserving keeps the locale's assets from being reclaimed; failing to
        // reserve (too many locales) does not prevent installation.
        _ = try? await AssetInventory.reserve(locale: resolved.locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [resolved.module]) else {
            // `nil` means either nothing is left to install or the system
            // offers nothing to download; only the status tells which. It used
            // to report success for both, leaving a missing model on screen
            // with no message.
            guard await AssetInventory.status(forModules: [resolved.module]) == .installed else {
                throw TranscriptionError.assetInstallUnavailable(resolved.locale.identifier(.bcp47))
            }
            await progress(1)
            return
        }
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { monitor.cancel() }
        try await request.downloadAndInstall()
        await progress(1)
    }

    /// A human-readable name for a locale in the current UI language.
    static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

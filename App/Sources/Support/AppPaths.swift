import Foundation
import HexMobileCore

/// On-device storage locations (Application Support, never synced).
enum AppPaths {
    /// The app's Application Support directory, created on first use and
    /// excluded from iCloud and computer backups: it holds dictation text.
    /// The flag is set on the directory because files in it are replaced
    /// atomically, which would drop a per-file flag.
    static var applicationSupport: URL {
        var url = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    /// Dictation history (see `HistoryStore`).
    static var historyFile: URL { applicationSupport.appending(path: "history.json") }

    /// Terms added on iPhone and not yet applied by the Mac.
    static var pendingVocabularyFile: URL { applicationSupport.appending(path: "pending-vocabulary.local.json") }

    /// Recordings of dictations in progress, for the accurate final pass. In
    /// Caches: never backed up, and the file is deleted as soon as the pass is
    /// done (``purgeTemporaryRecordings()`` removes what a crash left behind).
    static var temporaryRecordings: URL {
        URL.cachesDirectory.appending(path: "recordings", directoryHint: .isDirectory)
    }

    /// A new file name for a recording in progress.
    static func newTemporaryRecordingURL() -> URL {
        temporaryRecordings.appending(path: "dictation-\(UUID().uuidString).caf")
    }

    /// Deletes every temporary recording. Called at launch, when none can be
    /// in progress. Returns how many files it removed.
    @discardableResult
    static func purgeTemporaryRecordings() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: temporaryRecordings, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for file in files where file.pathExtension == "caf" {
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// The kept recordings (opt-in, see `SettingsStore.keepAudioClips`): audio
    /// and metadata of the last 20 dictations. In Application Support, so
    /// never synced; the library marks its folder as excluded from backups.
    static var clipLibrary: ClipLibrary {
        ClipLibrary(directory: applicationSupport.appending(path: "clips", directoryHint: .isDirectory))
    }

    /// Where the Whisper model is looked for (`Library/Application Support/whisper`).
    /// Nothing in the app creates or fills it: the model is copied here from a
    /// Mac with `make push-whisper-model`, so the app needs no network code
    /// for it. The folder is not created here either.
    static var whisperRoot: URL {
        applicationSupport.appending(path: WhisperLocator.rootName, directoryHint: .isDirectory)
    }

    /// What is installed under ``whisperRoot``. The copy comes from outside the
    /// app, so the folder is marked as excluded from backups here, where the
    /// flag can be set, every time it is found.
    static func whisperAvailability() -> WhisperAvailability {
        var root = whisperRoot
        if FileManager.default.fileExists(atPath: root.path) {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? root.setResourceValues(values)
        }
        return WhisperLocator.locate(root: root)
    }

    /// Last synced bundle, so rules keep working when the folder is unavailable.
    static var cachedBundleFile: URL { applicationSupport.appending(path: "hex-mobile-sync.cached.json") }
}

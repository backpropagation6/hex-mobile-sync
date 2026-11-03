import UIKit

/// Asks iOS for time to finish what follows a stop (final pass, cleanup, hand
/// off) when the app is in the background, and gives it back with ``end()``.
///
/// With the audio session active the app keeps running anyway; the Action
/// Button dump of 1 Nov 2026 showed `backgroundTimeRemaining=32s` with no audio
/// at all. The steps have their own deadlines (``FinalPassPolicy``) well under
/// that, and this is the belt for the braces.
@MainActor
final class BackgroundTaskScope {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private let name: String

    init(name: String) {
        self.name = name
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                Diagnostics.record("background task expired name=\(name)")
                self?.end()
            }
        }
        if identifier == .invalid {
            Diagnostics.record("background task refused name=\(name)")
        }
    }

    /// Ends the task. Safe to call twice.
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

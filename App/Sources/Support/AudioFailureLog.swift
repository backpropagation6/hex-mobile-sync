import AVFAudio
import Foundation
import OSLog
import UIKit

/// What the process itself logged about audio in the seconds before an
/// `engine.start` failure, kept in `audio-failure-oslog.log` (Application
/// Support, excluded from backups) next to `diagnostics.log`.
///
/// Why: the device log of 1 Nov 2026 shows `engine.start` failing with
/// `'what'` (2003329396) on the first Action Button press and working on the
/// next one, and the error code alone does not say why. CoreAudio, AVFAudio
/// and AudioToolbox log inside this process; `OSLogStore(scope:
/// .currentProcessIdentifier)` can read those entries back without any
/// entitlement. ipotesi: they name the cause. Not yet seen on a device: the
/// failure does not happen on the simulator.
///
/// One block per start (the first `engine.start` failure of it): a header line
/// with the time and the state of the app and the audio session, then up to
/// ``maxEntries`` entries of ``window`` seconds, each cut to ``maxLineLength``
/// characters. Only entries of audio frameworks are kept (the sender, the
/// subsystem or the category contains `audio`). The file keeps its last
/// ``maxFileLines`` lines. The log store is read off the main thread and the
/// start does not wait for it. Never logs dictated text: the entries are what
/// the system frameworks wrote, and the system redacts dynamic strings.
enum AudioFailureLog {
    /// Seconds of log before the failure.
    static let window: TimeInterval = 5
    static let maxEntries = 40
    static let maxLineLength = 240
    static let maxFileLines = 500

    /// Entries are kept when their sender, subsystem or category contains one
    /// of these (lowercase). `audio` covers CoreAudio, AVFAudio, AudioToolbox
    /// and AVAudioSession.
    private static let keywords = ["audio"]

    static var file: URL { AppPaths.applicationSupport.appending(path: "audio-failure-oslog.log") }

    /// Serializes the read-modify-write of the file.
    private static let fileLock = NSLock()

    /// Starts the dump for a failure that happened now. Cheap on the caller:
    /// the state is read here (it needs the main actor), the log store and the
    /// file are handled in a background task, which writes one line to
    /// `diagnostics.log` when it is done (`oslog dumped n=…`).
    /// - Parameter path: `flow` or `start`, as in the `audio attempt failed` line.
    @MainActor
    static func capture(path: String, attempt: Int) {
        let failedAt = Date()
        let header = "=== \(failedAt.ISO8601Format()) path=\(path) attempt=\(attempt) \(contextSummary())"
        Task.detached(priority: .utility) {
            let outcome = write(header: header, failedAt: failedAt)
            await Diagnostics.record(outcome)
        }
    }

    /// `applicationState=background backgroundTimeRemaining=unlimited
    /// recordPermission=granted isInputAvailable=true
    /// secondaryAudioShouldBeSilencedHint=false category=playAndRecord
    /// mode=default options=mixWithOthers,allowBluetoothHFP,defaultToSpeaker`.
    @MainActor
    private static func contextSummary() -> String {
        let application = UIApplication.shared
        let state: String = switch application.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        let remaining = application.backgroundTimeRemaining
        let background = remaining > 100_000 ? "unlimited" : String(format: "%.0fs", remaining)
        let permission: String = switch Permissions.microphone {
        case .granted: "granted"
        case .denied: "denied"
        case .undetermined: "undetermined"
        }
        let session = AVAudioSession.sharedInstance()
        let names: [(AVAudioSession.CategoryOptions, String)] = [
            (.mixWithOthers, "mixWithOthers"), (.duckOthers, "duckOthers"),
            (.interruptSpokenAudioAndMixWithOthers, "interruptSpokenAudioAndMixWithOthers"),
            (.allowBluetoothHFP, "allowBluetoothHFP"), (.allowBluetoothA2DP, "allowBluetoothA2DP"),
            (.allowAirPlay, "allowAirPlay"), (.defaultToSpeaker, "defaultToSpeaker"),
            (.overrideMutedMicrophoneInterruption, "overrideMutedMicrophoneInterruption"),
        ]
        let options = names.filter { session.categoryOptions.contains($0.0) }.map(\.1)
        return "applicationState=\(state) backgroundTimeRemaining=\(background) "
            + "recordPermission=\(permission) isInputAvailable=\(session.isInputAvailable) "
            + "secondaryAudioShouldBeSilencedHint=\(session.secondaryAudioShouldBeSilencedHint) "
            + "category=\(session.category.rawValue) mode=\(session.mode.rawValue) "
            + "options=\(options.isEmpty ? "-" : options.joined(separator: ","))"
    }

    /// Reads the log store and appends the block. Returns the line for
    /// `diagnostics.log`. Runs off the main actor.
    private nonisolated static func write(header: String, failedAt: Date) -> String {
        let lines: [String]
        let scanned: Int
        do {
            (lines, scanned) = try entries(before: failedAt)
        } catch {
            append(block: [header, "(log store unavailable: \(String(describing: error).prefix(200)))"])
            return "oslog dump failed error=\(String(describing: error).prefix(100))"
        }
        append(block: [header] + lines)
        return "oslog dumped n=\(lines.count) scanned=\(scanned) window=\(Int(window))s file=\(file.lastPathComponent)"
    }

    /// The audio entries of the last ``window`` seconds up to just after
    /// `failedAt`, newest ``maxEntries``, and how many entries were scanned.
    private nonisolated static func entries(before failedAt: Date) throws -> (lines: [String], scanned: Int) {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: failedAt.addingTimeInterval(-window))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss.SSS"
        var lines: [String] = []
        var scanned = 0
        // A little past the failure: the framework logs its error just before
        // it throws, and the read starts a moment after.
        let end = failedAt.addingTimeInterval(0.25)
        for entry in try store.getEntries(at: position) {
            guard entry.date <= end else { break }
            scanned += 1
            guard let log = entry as? OSLogEntryLog else { continue }
            let origin = "\(log.sender) \(log.subsystem) \(log.category)".lowercased()
            guard keywords.contains(where: { origin.contains($0) }) else { continue }
            let message = log.composedMessage.replacingOccurrences(of: "\n", with: " | ")
            let name = log.subsystem.isEmpty ? log.sender : "\(log.subsystem)/\(log.category)"
            let line = "\(formatter.string(from: log.date)) \(level(log.level)) \(name) [\(log.sender)] \(message)"
            lines.append(String(line.prefix(maxLineLength)))
        }
        return (Array(lines.suffix(maxEntries)), scanned)
    }

    private nonisolated static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: "-"
        case .debug: "D"
        case .info: "I"
        case .notice: "N"
        case .error: "E"
        case .fault: "F"
        @unknown default: "?"
        }
    }

    /// Appends `block` and keeps the last ``maxFileLines`` lines.
    private nonisolated static func append(block: [String]) {
        fileLock.lock()
        defer { fileLock.unlock() }
        let existing = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let text = (existing + block).suffix(maxFileLines).joined(separator: "\n") + "\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }
}

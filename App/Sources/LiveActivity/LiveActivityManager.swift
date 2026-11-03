import ActivityKit
import Foundation
import os

/// Starts, updates and ends the dictation Live Activity.
///
/// iOS requires a Live Activity while an `AudioRecordingIntent` records in
/// the background; the app also shows one during flow sessions so the user
/// always sees that the microphone is in use.
///
/// `Activity` is not `Sendable`, so the work happens in nonisolated static
/// functions that look the activity up by id instead of storing it.
@MainActor
final class LiveActivityManager {
    typealias Phase = DictationActivityAttributes.ContentState.Phase

    private var activityID: String?
    /// Why the last request failed (shown to the user, logged without text).
    private(set) var lastFailure: String?
    /// Whether the last successful `show` requested a new activity (`true`)
    /// or updated an existing one. Logged with every failed audio attempt
    /// (diagnostics only).
    private(set) var lastShowRequestedNewActivity = false
    /// When this process last requested an activity from ActivityKit.
    private var requestedAt: Date?
    /// Whether the flow session has no idle timeout (Settings > End After Idle
    /// > Never); the Live Activity says so while the session is up. Set by the
    /// controller, read at every ``show``.
    var sessionNeverEnds: @MainActor () -> Bool = { false }
    /// The last value written to the activity, to log only changes.
    private var lastNeverEnds = false

    /// Shows or updates the activity for `phase`.
    /// - Parameter fresh: end every existing activity and request a new one
    ///   instead of updating this launch's activity. An Action Button start
    ///   passes `true`, so the activity is requested by the `perform()` that
    ///   starts the audio (see ``DictationController``; not shown to be what
    ///   makes the audio start).
    /// - Returns: whether an activity is active now. `false` when Live
    ///   Activities are turned off for the app or the system refused the
    ///   request; recording started from an `AudioRecordingIntent` must not
    ///   go ahead without one.
    @discardableResult
    func show(phase: Phase, recordingStartedAt: Date?, isFlowSession: Bool, liveText: String? = nil, level: Double? = nil, refining: Bool = false, fresh: Bool = false) async -> Bool {
        // Only while the microphone is held for the session: not in standby
        // (microphone off) and not while a text waits for the keyboard.
        let neverEnds = isFlowSession && sessionNeverEnds() && phase != .standby && phase != .handoff
        if neverEnds != lastNeverEnds {
            lastNeverEnds = neverEnds
            Diagnostics.record("live activity neverEnds=\(neverEnds) phase=\(phase.rawValue)")
        }
        let outcome = await Self.show(
            existingID: activityID,
            state: DictationActivityAttributes.ContentState(phase: phase, recordingStartedAt: recordingStartedAt, liveText: liveText, level: level, neverEnds: neverEnds ? true : nil, refining: refining ? true : nil),
            isFlowSession: isFlowSession,
            fresh: fresh
        )
        switch outcome {
        case .success(let shown):
            activityID = shown.id
            lastFailure = nil
            lastShowRequestedNewActivity = shown.requested
            if shown.requested { requestedAt = Date() }
        case .failure(let failure):
            activityID = nil
            requestedAt = nil
            lastShowRequestedNewActivity = false
            lastFailure = failure.message
            Self.logger.error("Live Activity request failed: \(failure.message, privacy: .public)")
        }
        return activityID != nil
    }

    /// Ends every dictation activity immediately (including stale ones left
    /// by a previous launch).
    func end() async {
        activityID = nil
        requestedAt = nil
        lastNeverEnds = false
        await Self.endAll()
    }

    /// Whether the activity this manager holds still exists and is `active`.
    /// `false` once it ended (the user dismissed it, the system ended it) or
    /// when none was ever shown.
    var hasActiveActivity: Bool {
        guard let activityID else { return false }
        return Self.isActive(id: activityID)
    }

    private nonisolated static func isActive(id: String) -> Bool {
        Activity<DictationActivityAttributes>.activities.contains { $0.id == id && $0.activityState == .active }
    }

    /// For the diagnostics log: how many dictation activities exist, with
    /// their state, and how long ago this process requested the current one.
    func diagnosticsSummary() -> String {
        let age = requestedAt.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "-"
        return "\(Self.activitySummary()) requestedNew=\(lastShowRequestedNewActivity) age=\(age)"
    }

    /// `n=2[3F2A:active,91BC:ended]`: id prefix and `activityState` of every
    /// dictation activity the system knows about.
    nonisolated static func activitySummary() -> String {
        let activities = Activity<DictationActivityAttributes>.activities
        let list = activities.map { "\($0.id.prefix(4)):\(String(describing: $0.activityState))" }
        return "n=\(activities.count)[\(list.joined(separator: ","))]"
    }

    private nonisolated static func show(
        existingID: String?,
        state: DictationActivityAttributes.ContentState,
        isFlowSession: Bool,
        fresh: Bool
    ) async -> Result<Shown, ActivityFailure> {
        let content = ActivityContent(state: state, staleDate: nil)
        let running = Activity<DictationActivityAttributes>.activities.filter { $0.activityState == .active }
        // Reuse only this launch's activity. Adopting one left by a previous
        // launch (the app was terminated in the background) made iOS refuse
        // the microphone with 'what' (1 Nov 2026): a background recording
        // needs an activity requested by this process, so end stale ones.
        //
        // `fresh` skips the reuse altogether. Device log of 1 Nov 2026
        // (afternoon): a first Action Button press with no flow session failed
        // 8 times in a row with 'what' on `engine.start`, and the next press
        // one second later, in the same process, succeeded; the failed press
        // had ended its activity, so the successful one requested a new
        // activity inside its own `perform()`. That correlation did not hold
        // in the evening log: a first press that requested its activity
        // inside its own `perform()` (`requestedNew=true age=0.1s`) failed 4
        // times just the same, and the next press worked. `fresh` stays so a
        // standby activity left by the previous session is never silently
        // reused; it is not known to be what makes the audio start.
        let match = fresh ? nil : existingID.flatMap { id in
            running.first { $0.id == id && $0.attributes.isFlowSession == isFlowSession }
        }
        if let match {
            await match.update(content)
            return .success(Shown(id: match.id, requested: false))
        }
        await endAll()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return .failure(ActivityFailure(message: "Live Activities are turned off for Hex Mobile"))
        }
        do {
            let activity = try Activity.request(
                attributes: DictationActivityAttributes(isFlowSession: isFlowSession),
                content: content,
                pushType: nil
            )
            return .success(Shown(id: activity.id, requested: true))
        } catch {
            return .failure(ActivityFailure(message: String(reflecting: error)))
        }
    }

    private nonisolated static let logger = Logger(subsystem: "io.github.hexmobile", category: "LiveActivity")

    struct ActivityFailure: Error {
        var message: String
    }

    /// The activity a ``show`` call ended up with.
    struct Shown: Sendable {
        var id: String
        /// `true` when ActivityKit was asked for a new activity, `false` when
        /// an existing one was updated.
        var requested: Bool
    }

    private nonisolated static func endAll() async {
        let final = ActivityContent(
            state: DictationActivityAttributes.ContentState(phase: .ready, recordingStartedAt: nil),
            staleDate: nil
        )
        for activity in Activity<DictationActivityAttributes>.activities {
            await activity.end(final, dismissalPolicy: .immediate)
        }
    }
}

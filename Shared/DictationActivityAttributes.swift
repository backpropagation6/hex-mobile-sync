import ActivityKit
import Foundation

/// Live Activity shown while the app records or keeps a flow session alive.
///
/// Compiled into the app (which starts, updates and ends the activity) and
/// into the widget extension (which renders it). iOS requires a Live Activity
/// while an `AudioRecordingIntent` records in the background.
struct DictationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// What the app is doing right now.
        enum Phase: String, Codable, Hashable, Sendable {
            /// Flow session alive, waiting for the keyboard or a shortcut.
            case ready
            /// Recording audio.
            case recording
            /// Microphone off, the island stays as a shortcut back to
            /// dictation (author's choice, 1 Nov 2026: always visible at rest).
            case standby
            /// Transcribing and applying text rules.
            case processing
            /// A text finished in the background is waiting for the Hex
            /// Mobile keyboard to take it (the flow session an Action Button
            /// press opened stays up for that, at most a minute). ``liveText``
            /// holds the start of the text; the activity asks to open the
            /// keyboard. The app and the widget extension are installed
            /// together, so an older extension never sees this phase.
            case handoff
        }

        var phase: Phase
        /// Start of the current recording (drives the elapsed timer).
        var recordingStartedAt: Date?
        /// The last words of the live transcript while recording, or the
        /// start of the text waiting for the keyboard in the `handoff` phase
        /// (shown on the Lock Screen and in the expanded Dynamic Island).
        var liveText: String? = nil
        /// Microphone level 0...1 at the last update, so the Dynamic Island
        /// wave follows the voice (the widget cannot animate on its own).
        var level: Double? = nil
        /// `true` while the flow session has no idle timeout (Settings > End
        /// After Idle > Never): the Lock Screen and the expanded island say
        /// the session stays up until the user ends it. `nil` otherwise (an
        /// older activity decodes as `nil`).
        var neverEnds: Bool? = nil
        /// `true` in the `processing` phase once the words are recognized and
        /// the app is fixing the text (accurate second pass, then cleanup):
        /// the title says «Fixing the text…» instead of «Transcribing…».
        /// `nil` otherwise (an older activity decodes as `nil`).
        var refining: Bool? = nil
    }

    /// Whether the activity belongs to a flow session (stays after each dictation).
    var isFlowSession: Bool
}

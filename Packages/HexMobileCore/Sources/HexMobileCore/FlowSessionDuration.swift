import Foundation

/// How long a flow session stays up with nothing to do, the choice behind
/// Settings > Flow Session > End After Idle.
///
/// The stored value is a number of minutes (`0` for ``never``), under the key
/// the first versions already used for a stepper from 1 to 30 minutes, so an
/// installed app keeps working: see ``init(storedMinutes:)``.
public enum FlowSessionDuration: Int, CaseIterable, Sendable {
    case minutes5 = 5
    case minutes15 = 15
    case minutes60 = 60
    /// The session ends only when the user ends it, or something outside the
    /// app does (an audio route change, an interruption, iOS ending the app or
    /// its Live Activity).
    case never = 0

    /// The default, as before the choice existed (5 minutes).
    public static let `default`: FlowSessionDuration = .minutes5

    /// The idle time in seconds, `nil` for ``never``.
    public var interval: TimeInterval? {
        self == .never ? nil : TimeInterval(rawValue * 60)
    }

    /// The idle time in minutes, `nil` for ``never``.
    public var minutes: Int? {
        self == .never ? nil : rawValue
    }

    /// Reads a stored number of minutes. Values from the old 1 to 30 minute
    /// stepper go up to the next choice (1 to 5 become 5, 6 to 15 become 15,
    /// 16 and more become 60): a session does not end sooner than the user
    /// asked. `0` is ``never``; a negative number is the default.
    public init(storedMinutes: Int) {
        switch storedMinutes {
        case ..<0: self = .default
        case 0: self = .never
        case 1...5: self = .minutes5
        case 6...15: self = .minutes15
        default: self = .minutes60
        }
    }
}

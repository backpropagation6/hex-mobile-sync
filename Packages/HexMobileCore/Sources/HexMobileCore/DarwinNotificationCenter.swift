import Foundation
import Synchronization

/// A small Sendable wrapper around the Darwin notify center
/// (`CFNotificationCenterGetDarwinNotifyCenter`), the only cross-process
/// signal available between an app and its extensions without an App Group.
///
/// Darwin notifications carry a name only: no object, no user info. Anything
/// richer goes through the pasteboard (see ``DictationPayload``).
///
/// Delivery: the system calls observers on the main thread when the main run
/// loop is running (apps and extensions), otherwise on a system queue. The
/// streams returned here are safe on either path.
public struct DarwinNotificationCenter: Sendable {
    /// The shared instance. The type is stateless; instances are interchangeable.
    public static let shared = DarwinNotificationCenter()

    /// Creates a center wrapper.
    public init() {}

    /// Posts the Darwin notification `name` to every process.
    public func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    /// Posts one of the app's signals.
    public func post(_ signal: HexMobileIPC.Signal) {
        post(signal.name)
    }

    /// Observes Darwin notifications by name.
    ///
    /// The stream yields the name of each delivered notification. Observation
    /// starts before this method returns and stops when the stream is
    /// cancelled or deallocated (for example when the consuming task ends).
    /// Notifications that arrive while nobody is iterating are buffered,
    /// keeping the newest `bufferLimit` names.
    public func notifications(named names: [String], bufferLimit: Int = 16) -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: String.self,
            bufferingPolicy: .bufferingNewest(max(1, bufferLimit))
        )
        let token = DarwinObservationRegistry.register(names: Array(Set(names)), continuation: continuation)
        continuation.onTermination = { _ in
            DarwinObservationRegistry.unregister(token)
        }
        return stream
    }

    /// Observes some of the app's signals. See ``notifications(named:bufferLimit:)``.
    public func signals(
        _ signals: [HexMobileIPC.Signal] = HexMobileIPC.Signal.allCases,
        bufferLimit: Int = 16
    ) -> AsyncStream<HexMobileIPC.Signal> {
        let names = notifications(named: signals.map(\.name), bufferLimit: bufferLimit)
        let (stream, continuation) = AsyncStream.makeStream(
            of: HexMobileIPC.Signal.self,
            bufferingPolicy: .bufferingNewest(max(1, bufferLimit))
        )
        let task = Task {
            for await name in names {
                if let signal = HexMobileIPC.Signal(name: name) {
                    continuation.yield(signal)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

/// Bookkeeping for live observations.
///
/// The CF observer pointer is not a real object: it is an integer token used
/// as a key into a locked table of continuations. A callback that races with
/// unregistration finds no entry and does nothing, so no memory is ever
/// dereferenced through the pointer, whichever thread the system calls on.
enum DarwinObservationRegistry {
    private struct State {
        var nextToken = 1
        var continuations: [Int: AsyncStream<String>.Continuation] = [:]
    }

    private static let state = Mutex(State())

    /// Number of observations currently registered (for tests).
    static var activeCount: Int {
        state.withLock { $0.continuations.count }
    }

    static func register(names: [String], continuation: AsyncStream<String>.Continuation) -> Int {
        let token = state.withLock { state in
            let token = state.nextToken
            state.nextToken += 1
            state.continuations[token] = continuation
            return token
        }
        guard let observer = UnsafeRawPointer(bitPattern: token) else { return token }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in names {
            CFNotificationCenterAddObserver(
                center,
                observer,
                { _, observer, name, _, _ in
                    guard let observer, let name else { return }
                    DarwinObservationRegistry.deliver(name.rawValue as String, to: Int(bitPattern: observer))
                },
                name as CFString,
                nil,
                .deliverImmediately
            )
        }
        return token
    }

    static func unregister(_ token: Int) {
        if let observer = UnsafeRawPointer(bitPattern: token) {
            CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer)
        }
        _ = state.withLock { $0.continuations.removeValue(forKey: token) }
    }

    private static func deliver(_ name: String, to token: Int) {
        let continuation = state.withLock { $0.continuations[token] }
        continuation?.yield(name)
    }
}

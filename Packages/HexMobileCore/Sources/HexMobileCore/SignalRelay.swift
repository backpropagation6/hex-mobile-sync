import Foundation

/// Delivers every element of one stream to a single, weakly held subscriber.
///
/// Why this exists (1 Nov 2026, keyboard on a device): each keyboard session
/// used to open its own Darwin stream, and a session that ended without
/// `viewDidDisappear` never closed it, so after twenty sessions every signal
/// arrived three times (and the dictation was inserted by whichever model
/// still believed it had Full Access). With a relay there is one stream per
/// process, opened once; the subscriber that attached last gets the elements
/// and an older one gets nothing, whether or not it released anything.
/// Nothing here depends on a teardown call: the subscriber is weak, so a
/// subscriber that is gone simply stops receiving.
@MainActor
public final class SignalRelay<Element: Sendable, Subscriber: AnyObject> {
    private weak var current: Subscriber?
    private let deliver: @MainActor (Subscriber, Element) -> Void
    private var task: Task<Void, Never>?

    /// Elements delivered to a subscriber so far (for logs and tests).
    public private(set) var deliveredCount = 0
    /// Elements that arrived while nobody was attached.
    public private(set) var droppedCount = 0

    /// Starts reading `stream` right away.
    /// - Parameters:
    ///   - stream: the one source of elements for the whole process.
    ///   - deliver: called on the main actor with the current subscriber.
    public init(
        stream: AsyncStream<Element>,
        deliver: @escaping @MainActor (Subscriber, Element) -> Void
    ) {
        self.deliver = deliver
        task = Task { [weak self] in
            for await element in stream {
                // The relay is gone: stop reading (ends the observation).
                guard let self else { return }
                self.receive(element)
            }
        }
    }

    isolated deinit {
        task?.cancel()
    }

    /// Makes `subscriber` the one that receives from now on.
    public func attach(_ subscriber: Subscriber) {
        current = subscriber
    }

    /// Stops delivering to `subscriber` if it is the current one.
    public func detach(_ subscriber: Subscriber) {
        if current === subscriber { current = nil }
    }

    /// The subscriber that receives now, if it is still alive.
    public var hasSubscriber: Bool { current != nil }

    private func receive(_ element: Element) {
        guard let current else {
            droppedCount += 1
            return
        }
        deliveredCount += 1
        deliver(current, element)
    }
}

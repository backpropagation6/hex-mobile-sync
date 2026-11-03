import Foundation
import Testing
@testable import HexMobileCore

/// Stands in for a `KeyboardModel`: records what it is handed.
@MainActor
private final class Listener {
    var received: [String] = []
}

/// Nested in the Darwin center's serialized suite: both read the process-wide
/// `DarwinObservationRegistry.activeCount`, so they must not overlap.
extension DarwinNotificationCenterTests {
    @Suite("Signal relay")
    @MainActor
    struct SignalRelayTests {
        private func uniqueName(_ label: String) -> String {
            "io.github.hexmobile.test.\(label).\(UUID().uuidString)"
        }

        /// Waits until `condition` holds, polling; false when it does not within `seconds`.
        private func waitUntil(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > deadline { return false }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return true
        }

        @Test("Five listeners left attached: one event reaches the last one, once", .timeLimit(.minutes(1)))
        func oneEventOneDelivery() async {
            // The device log of 1 Nov 2026: models whose keyboard had gone stayed
            // subscribed and every signal arrived once per model.
            let event = uniqueName("event")
            let end = uniqueName("end")
            let relay = SignalRelay<String, Listener>(
                stream: DarwinNotificationCenter.shared.notifications(named: [event, end])
            ) { listener, name in
                listener.received.append(name)
            }
            let listeners = (0..<5).map { _ in Listener() }
            for listener in listeners { relay.attach(listener) }

            DarwinNotificationCenter.shared.post(event)
            DarwinNotificationCenter.shared.post(end)
            let last = listeners[4]
            // Both notifications are delivered in order, so once `end` is in, `event` was too.
            #expect(await waitUntil { last.received.contains(end) })

            #expect(last.received == [event, end])
            for stale in listeners.dropLast() { #expect(stale.received.isEmpty) }
            #expect(relay.deliveredCount == 2)
            #expect(relay.droppedCount == 0)
        }

        @Test("The relay does not keep its subscriber alive", .timeLimit(.minutes(1)))
        func subscriberIsWeak() async {
            let event = uniqueName("event")
            let relay = SignalRelay<String, Listener>(
                stream: DarwinNotificationCenter.shared.notifications(named: [event])
            ) { listener, name in
                listener.received.append(name)
            }
            weak var weakListener: Listener?
            do {
                let listener = Listener()
                weakListener = listener
                relay.attach(listener)
            }
            #expect(weakListener == nil)
            #expect(!relay.hasSubscriber)

            DarwinNotificationCenter.shared.post(event)
            #expect(await waitUntil { relay.droppedCount == 1 })
            #expect(relay.deliveredCount == 0)
        }

        @Test("Detaching an old subscriber does not take the current one away", .timeLimit(.minutes(1)))
        func detachOnlyTheCurrent() async {
            let event = uniqueName("event")
            let relay = SignalRelay<String, Listener>(
                stream: DarwinNotificationCenter.shared.notifications(named: [event])
            ) { listener, name in
                listener.received.append(name)
            }
            let older = Listener()
            let newer = Listener()
            relay.attach(older)
            relay.attach(newer)
            relay.detach(older)
            #expect(relay.hasSubscriber)

            DarwinNotificationCenter.shared.post(event)
            #expect(await waitUntil { !newer.received.isEmpty })
            #expect(newer.received == [event])
            #expect(older.received.isEmpty)

            relay.detach(newer)
            #expect(!relay.hasSubscriber)
            DarwinNotificationCenter.shared.post(event)
            #expect(await waitUntil { relay.droppedCount == 1 })
            #expect(newer.received == [event])
        }

        @Test("Releasing the relay ends its observation", .timeLimit(.minutes(1)))
        func releaseEndsObservation() async {
            let baseline = DarwinObservationRegistry.activeCount
            var relay: SignalRelay<String, Listener>? = SignalRelay(
                stream: DarwinNotificationCenter.shared.notifications(named: [uniqueName("event")])
            ) { _, _ in }
            #expect(DarwinObservationRegistry.activeCount == baseline + 1)
            relay = nil
            #expect(await waitUntil { DarwinObservationRegistry.activeCount == baseline })
            _ = relay
        }
    }
}

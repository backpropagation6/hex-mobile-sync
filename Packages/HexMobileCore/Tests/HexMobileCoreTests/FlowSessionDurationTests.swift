import Testing
@testable import HexMobileCore

@Suite("Flow session duration")
struct FlowSessionDurationTests {
    @Test("The choices, in the order the picker shows them")
    func choices() {
        #expect(FlowSessionDuration.allCases == [.minutes5, .minutes15, .minutes60, .never])
        #expect(FlowSessionDuration.default == .minutes5)
        #expect(FlowSessionDuration.allCases.map(\.rawValue) == [5, 15, 60, 0])
    }

    @Test("Intervals: minutes in seconds, nil for Never")
    func intervals() {
        #expect(FlowSessionDuration.minutes5.interval == 300)
        #expect(FlowSessionDuration.minutes15.interval == 900)
        #expect(FlowSessionDuration.minutes60.interval == 3600)
        #expect(FlowSessionDuration.never.interval == nil)
        #expect(FlowSessionDuration.minutes15.minutes == 15)
        #expect(FlowSessionDuration.never.minutes == nil)
    }

    @Test("Stored minutes round up to the next choice, never down")
    func storedMinutes() {
        #expect(FlowSessionDuration(storedMinutes: 1) == .minutes5)
        #expect(FlowSessionDuration(storedMinutes: 5) == .minutes5)
        #expect(FlowSessionDuration(storedMinutes: 6) == .minutes15)
        #expect(FlowSessionDuration(storedMinutes: 10) == .minutes15)
        #expect(FlowSessionDuration(storedMinutes: 15) == .minutes15)
        #expect(FlowSessionDuration(storedMinutes: 16) == .minutes60)
        #expect(FlowSessionDuration(storedMinutes: 30) == .minutes60)
        #expect(FlowSessionDuration(storedMinutes: 60) == .minutes60)
        #expect(FlowSessionDuration(storedMinutes: 500) == .minutes60)
        #expect(FlowSessionDuration(storedMinutes: 0) == .never)
        #expect(FlowSessionDuration(storedMinutes: -3) == .default)
    }

    @Test("Every choice reads back from its own stored value")
    func roundTrip() {
        for choice in FlowSessionDuration.allCases {
            #expect(FlowSessionDuration(storedMinutes: choice.rawValue) == choice)
        }
    }
}

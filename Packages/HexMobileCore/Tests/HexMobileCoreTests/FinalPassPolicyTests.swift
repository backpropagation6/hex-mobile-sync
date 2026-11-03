import Foundation
import Testing
@testable import HexMobileCore

@Suite("FinalPassPolicy")
struct FinalPassPolicyTests {
    @Test("the final pass timeout grows with the recording and stays in 3...5 s")
    func timeout() {
        #expect(FinalPassPolicy.finalPassTimeout(forRecordingSeconds: 0) == 3)
        #expect(FinalPassPolicy.finalPassTimeout(forRecordingSeconds: 10) == 3)
        #expect(FinalPassPolicy.finalPassTimeout(forRecordingSeconds: 40) == 4)
        #expect(FinalPassPolicy.finalPassTimeout(forRecordingSeconds: 60) == 5)
        #expect(FinalPassPolicy.finalPassTimeout(forRecordingSeconds: 3600) == 5)
        #expect(FinalPassPolicy.finalPassTimeout(forRecordingSeconds: -5) == 3)
    }

    @Test("the ceiling leaves a short text's cleanup its time inside the 8 s budget")
    func ceilingLeavesCleanupTime() {
        #expect(FinalPassPolicy.finalPassCeiling + FinalPassPolicy.cleanupTimeout == FinalPassPolicy.totalBudget)
        // The slowest final pass ends at 5 s: a cleanup of 90 characters (0.6 s) still starts,
        // with what is left until the deadline.
        let worst = FinalPassPolicy.finalPassTimeout(forRecordingSeconds: 1000)
        guard case let .run(timeout) = FinalPassPolicy.cleanupPlan(elapsedSinceStop: worst, characters: 90) else {
            Issue.record("a short cleanup after the slowest final pass should start")
            return
        }
        #expect(abs(timeout - (FinalPassPolicy.cleanupDeadline - worst)) < 1e-9)
    }

    @Test("the cleanup does not start when its estimate does not fit before the deadline")
    func cleanupSkipsWhenItWouldOverrun() {
        // Phone, 2 Nov 2026: 1890 characters after Apple's 1.3 s timed out at 6.6 s.
        let estimate = FinalPassPolicy.cleanupEstimate(characters: 1890)
        #expect(FinalPassPolicy.cleanupPlan(elapsedSinceStop: 1.3, characters: 1890)
            == .skip(estimate: estimate, available: FinalPassPolicy.cleanupDeadline - 1.3))
        #expect(estimate > FinalPassPolicy.cleanupDeadline - 1.3)
        // 1127 characters took 4.19 s: after 0.8 s it starts, with all that is left.
        #expect(FinalPassPolicy.cleanupPlan(elapsedSinceStop: 0.8, characters: 1127)
            == .run(timeout: FinalPassPolicy.cleanupDeadline - 0.8))
        // The edge for this text is 7.55 - 4.65 = 2.9 s after the stop.
        #expect(FinalPassPolicy.cleanupPlan(elapsedSinceStop: 2.9, characters: 1127)
            == .run(timeout: FinalPassPolicy.cleanupDeadline - 2.9))
        if case .run = FinalPassPolicy.cleanupPlan(elapsedSinceStop: 3.0, characters: 1127) {
            Issue.record("1127 characters 3.0 s after the stop need 4.65 s and only 4.55 s are left")
        }
    }

    @Test("the cleanup's time is the absolute deadline, whatever the clock says")
    func cleanupDeadlineIsAbsolute() {
        #expect(FinalPassPolicy.cleanupDeadline == FinalPassPolicy.totalBudget - FinalPassPolicy.endToEndMargin)
        #expect(FinalPassPolicy.endToEndMargin >= 0.4 && FinalPassPolicy.endToEndMargin <= 0.5)
        for characters in [0, 90, 435, 760, 1127] {
            for elapsed in stride(from: 0.0, through: 7.0, by: 0.25) {
                if case let .run(timeout) = FinalPassPolicy.cleanupPlan(elapsedSinceStop: elapsed, characters: characters) {
                    #expect(abs(elapsed + timeout - FinalPassPolicy.cleanupDeadline) < 1e-9)
                    #expect(timeout >= FinalPassPolicy.minimumCleanupTime)
                    #expect(timeout >= FinalPassPolicy.cleanupEstimate(characters: characters))
                }
            }
        }
    }

    @Test("a short text still needs a second, and nothing starts after the deadline")
    func cleanupMinimum() {
        // 90 characters are 0.6 s of work, but under a second the model does not get going.
        #expect(FinalPassPolicy.cleanupPlan(elapsedSinceStop: 6.5, characters: 90)
            == .run(timeout: FinalPassPolicy.cleanupDeadline - 6.5))
        #expect(FinalPassPolicy.cleanupPlan(elapsedSinceStop: 6.6, characters: 90)
            == .skip(estimate: FinalPassPolicy.cleanupEstimate(characters: 90), available: FinalPassPolicy.cleanupDeadline - 6.6))
        #expect(FinalPassPolicy.cleanupPlan(elapsedSinceStop: 9, characters: 90)
            == .skip(estimate: FinalPassPolicy.cleanupEstimate(characters: 90), available: 0))
        #expect(FinalPassPolicy.cleanupPlan(elapsedSinceStop: -1, characters: 0) == .run(timeout: FinalPassPolicy.cleanupDeadline))
    }

    @Test("a final text with the live words is used")
    func usesFinal() {
        #expect(FinalPassPolicy.decide(live: "Sta rompando proprio alla grande", final: "Sta rompendo proprio alla grande.") == .useFinal)
        // The final pass may find words the live transcript missed.
        #expect(FinalPassPolicy.decide(live: "dobbiamo aggiornare il modello su Jing", final: "dobbiamo aggiornare il modello su Jing Fail e poi rifare") == .useFinal)
        #expect(FinalPassPolicy.decide(live: "", final: "una parola") == .useFinal)
    }

    @Test("an empty final text falls back to the live words")
    func emptyFinal() {
        #expect(FinalPassPolicy.decide(live: "ciao a tutti", final: "") == .useLive(.empty))
        #expect(FinalPassPolicy.decide(live: "ciao a tutti", final: "  \n") == .useLive(.empty))
        #expect(FinalPassPolicy.decide(live: "ciao a tutti", final: nil) == .useLive(.empty))
    }

    @Test("a final text with less than half of the live words falls back")
    func shortFinal() {
        let live = "uno due tre quattro cinque sei sette otto"
        #expect(FinalPassPolicy.decide(live: live, final: "uno due tre") == .useLive(.short))
        #expect(FinalPassPolicy.decide(live: live, final: "uno due tre quattro") == .useFinal)
    }

    @Test("nothing from either side is not a fallback")
    func bothEmpty() {
        #expect(FinalPassPolicy.decide(live: "", final: "") == .useFinal)
        #expect(FinalPassPolicy.decide(live: " ", final: nil) == .useFinal)
    }
}

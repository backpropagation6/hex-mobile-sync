import Foundation
import HexMobileCore
import Testing
@testable import HexMobileSpeech

/// A pass that answers from a closure after an optional pause.
private struct ScriptedEngine: FinalPassEngine {
    var name = "scripted"
    var delay: Duration = .zero
    var answer: @Sendable () throws -> String

    func transcribe(fileURL: URL, locale: Locale, contextualStrings: [String]) async throws -> String {
        if delay > .zero { try await Task.sleep(for: delay) }
        return try answer()
    }
}

private struct Boom: Error {}

private let file = URL(fileURLWithPath: "/nonexistent/clip.caf")

@Suite("FinalPass.run")
struct FinalPassTests {
    @Test("a good text replaces the one in hand and reports the real-time factor")
    func ok() async {
        let engine = ScriptedEngine(delay: .milliseconds(20)) { "Sta rompendo proprio alla grande." }
        let report = await FinalPass.run(
            engine: engine, fileURL: file, locale: Locale(identifier: "it-IT"), contextualStrings: [],
            live: "Sta rompando proprio alla grande", recordingSeconds: 2
        )
        #expect(report.outcome == .ok)
        #expect(report.text == "Sta rompendo proprio alla grande.")
        #expect(report.engine == "scripted")
        let factor = report.realTimeFactor ?? -1
        #expect(factor > 0 && factor < 2)
        #expect(report.logLine.hasPrefix("final pass dt="))
        #expect(report.logLine.contains("outcome=ok engine=scripted reason=- live=32 final=33 rtf="))
        #expect(!report.logLine.hasSuffix("rtf=-"))
    }

    @Test("the deadline can be given, and a pass that misses it leaves the text in hand")
    func timeoutOverride() async {
        let engine = ScriptedEngine(delay: .seconds(5)) { "never" }
        let started = ContinuousClock.now
        let report = await FinalPass.run(
            engine: engine, fileURL: file, locale: Locale(identifier: "it-IT"), contextualStrings: [],
            live: "testo in mano", recordingSeconds: 1, timeout: 0.1
        )
        let waited = started.duration(to: .now)
        #expect(report.outcome == .fallback)
        #expect(report.reason == "timeout")
        #expect(report.text == "testo in mano")
        #expect(waited < .seconds(2))
        // A pass that ran out of time says nothing about the model's speed.
        #expect(report.realTimeFactor == nil)
        #expect(report.logLine.hasSuffix("rtf=-"))
    }

    @Test("the second pass is named after what it is compared with")
    func baselineLabel() async {
        let engine = ScriptedEngine(name: "whisper") { "uno due tre quattro" }
        let report = await FinalPass.run(
            engine: engine, fileURL: file, locale: Locale(identifier: "it-IT"), contextualStrings: [],
            live: "uno due tre", recordingSeconds: 3, timeout: 1, baseline: "apple"
        )
        #expect(report.outcome == .ok)
        #expect(report.logLine.contains("engine=whisper reason=- apple=11 final=19"))
        #expect(!report.logLine.contains("live="))
    }

    @Test("a sentence lost in the middle: with the gap guard on, the text in hand stays and the report says where")
    func gap() async throws {
        let apple = "ho chiamato Mauro per il preventivo e poi gli ho scritto la mail con tutti i dettagli del lavoro che dobbiamo fare entro venerdi"
        let lost = "ho chiamato Mauro per il preventivo e poi gli ho scritto la mail entro venerdi"
        let engine = ScriptedEngine(name: "whisper") { lost }
        let report = await FinalPass.run(
            engine: engine, fileURL: file, locale: Locale(identifier: "it-IT"), contextualStrings: [],
            live: apple, recordingSeconds: 8, timeout: 1, baseline: "apple", gapGuard: 5
        )
        #expect(report.outcome == .fallback)
        #expect(report.reason == "gap")
        #expect(report.text == apple)
        #expect(report.rawFinal == lost)
        let gap = try #require(report.gap)
        #expect(gap.missing == 9)
        #expect(gap.at == 13)
        #expect(report.guardLogLine == "guard gap=9 at=13 engine=whisper apple_words=24 final_words=15 unmatched=9 written=0")
        #expect(report.logLine.contains("outcome=fallback engine=whisper reason=gap apple="))
        #expect(report.realTimeFactor == nil)
    }

    @Test("the same lost sentence passes when the guard is off, and a complete text passes with it on")
    func gapOffAndComplete() async {
        let apple = "ho chiamato Mauro per il preventivo e poi gli ho scritto la mail con tutti i dettagli del lavoro che dobbiamo fare entro venerdi"
        let lost = "ho chiamato Mauro per il preventivo e poi gli ho scritto la mail entro venerdi"
        let off = await FinalPass.run(
            engine: ScriptedEngine(name: "whisper") { lost }, fileURL: file, locale: Locale(identifier: "it-IT"),
            contextualStrings: [], live: apple, recordingSeconds: 8, timeout: 1, baseline: "apple"
        )
        #expect(off.outcome == .ok)
        #expect(off.guardLogLine == nil)
        let complete = await FinalPass.run(
            engine: ScriptedEngine(name: "whisper") { apple + "." }, fileURL: file, locale: Locale(identifier: "it-IT"),
            contextualStrings: [], live: apple, recordingSeconds: 8, timeout: 1, baseline: "apple", gapGuard: 5
        )
        #expect(complete.outcome == .ok)
        #expect(complete.gap == nil)
    }

    @Test("a loss covered by invented words is refused too, and the log carries both counts")
    func coveredGap() async throws {
        let apple = "ho incontrato Marco alle nove del mattino nella sala riunioni del piano e poi siamo andati a pranzo"
        let covered = "ho incontrato Marco sottotitoli creati dalla comunita amara e poi siamo andati a pranzo"
        let report = await FinalPass.run(
            engine: ScriptedEngine(name: "whisper") { covered }, fileURL: file, locale: Locale(identifier: "it-IT"),
            contextualStrings: [], live: apple, recordingSeconds: 8, timeout: 1, baseline: "apple", gapGuard: 5
        )
        #expect(report.reason == "gap")
        #expect(report.text == apple)
        let gap = try #require(report.gap)
        #expect(gap.missing == 4)
        #expect(report.guardLogLine == "guard gap=4 at=3 engine=whisper apple_words=18 final_words=14 unmatched=9 written=5")
    }

    @Test("texts too long to compare pass unjudged, and the log says so")
    func notJudged() async throws {
        let long = (0..<1200).map { "parola\($0)" }.joined(separator: " ")
        let other = (0..<900).map { "altra\($0)" }.joined(separator: " ")
        let report = await FinalPass.run(
            engine: ScriptedEngine(name: "whisper") { other }, fileURL: file, locale: Locale(identifier: "it-IT"),
            contextualStrings: [], live: long, recordingSeconds: 8, timeout: 5, baseline: "apple", gapGuard: 5
        )
        // 900 words against 1200 is above half: the length rule lets it through, the guard cannot look.
        #expect(report.outcome == .ok)
        #expect(report.gap == nil)
        #expect(report.guardLogLine == "guard skipped reason=too-long cells=\(1201 * 901) engine=whisper apple_words=1200 final_words=900")
    }

    @Test("less than half of the words in hand: the text in hand stays")
    func short() async {
        let engine = ScriptedEngine(name: "whisper") { "uno" }
        let report = await FinalPass.run(
            engine: engine, fileURL: file, locale: Locale(identifier: "it-IT"), contextualStrings: [],
            live: "uno due tre quattro cinque", recordingSeconds: 3, timeout: 1, baseline: "apple"
        )
        #expect(report.outcome == .fallback)
        #expect(report.reason == "short")
        #expect(report.text == "uno due tre quattro cinque")
        #expect(report.rawFinal == "uno")
    }

    @Test("an error is a fallback with its domain and code")
    func error() async {
        let engine = ScriptedEngine { throw Boom() }
        let report = await FinalPass.run(
            engine: engine, fileURL: file, locale: Locale(identifier: "it-IT"), contextualStrings: [],
            live: "testo", recordingSeconds: 1
        )
        #expect(report.outcome == .fallback)
        #expect(report.reason.hasPrefix("error:"))
        #expect(report.text == "testo")
    }

    @Test("a pass that was not started is a fallback with its reason and no time")
    func skipped() {
        let report = FinalPass.skipped(
            engine: "whisper", reason: .budget, text: "testo di Apple", recordingSeconds: 12, baseline: "apple"
        )
        #expect(report.outcome == .fallback)
        #expect(report.reason == "budget")
        #expect(report.text == "testo di Apple")
        #expect(report.seconds == 0)
        #expect(report.logLine == "final pass dt=0.00 outcome=fallback engine=whisper reason=budget apple=14 final=0 rtf=-")

        let notReady = FinalPass.skipped(engine: "whisper", reason: .notReady, text: "x")
        #expect(notReady.reason == "not-ready")
    }
}

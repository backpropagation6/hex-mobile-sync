import Foundation
import Testing
@testable import HexMobileCore

@Suite("TranscriptText")
struct TranscriptTextTests {
    @Test("segments are joined with one space")
    func join() {
        #expect("".appendingSegment("ciao") == "ciao")
        #expect("ciao".appendingSegment("a tutti") == "ciao a tutti")
        #expect("ciao ".appendingSegment(" a tutti ") == "ciao a tutti")
        #expect("ciao".appendingSegment("  ") == "ciao")
    }

    @Test("a segment that starts with punctuation sticks to the text")
    func punctuation() {
        #expect("ciao".appendingSegment(", come stai") == "ciao, come stai")
        #expect("ciao".appendingSegment("(a presto)") == "ciao (a presto)")
    }

    @Test("a capital at the start of a later segment is kept: names must survive")
    func midSentenceCapital() {
        // 1 Nov 2026: «Okay, quindi Funziona tutto.» is two segments. The
        // join does not lowercase; the cleanup step repairs it.
        #expect("Okay, quindi".appendingSegment("Funziona tutto.") == "Okay, quindi Funziona tutto.")
    }

    @Test("finals are appended and the volatile tail is replaced")
    func assembler() {
        var assembler = TranscriptAssembler()
        #expect(assembler.isEmpty)
        assembler.receive(text: "Ciao", isFinal: false)
        #expect(assembler.text == "Ciao")
        assembler.receive(text: "Ciao a", isFinal: false)
        #expect(assembler.text == "Ciao a")
        assembler.receive(text: "Ciao a tutti.", isFinal: true)
        #expect(assembler.finalized == "Ciao a tutti.")
        #expect(assembler.volatile == "")
        assembler.receive(text: "Come", isFinal: false)
        assembler.receive(text: "Come stai", isFinal: false)
        #expect(assembler.text == "Ciao a tutti. Come stai")
        assembler.receive(text: "Come stai?", isFinal: true)
        #expect(assembler.text == "Ciao a tutti. Come stai?")
        assembler.reset()
        #expect(assembler.isEmpty)
    }

    @Test("a long dictation keeps every sentence in order")
    func longDictation() {
        var assembler = TranscriptAssembler()
        var expected: [String] = []
        for index in 1...60 {
            let sentence = "Frase numero \(index) della dettatura lunga."
            expected.append(sentence)
            assembler.receive(text: "Frase numero \(index)", isFinal: false)
            assembler.receive(text: sentence, isFinal: true)
        }
        #expect(assembler.text == expected.joined(separator: " "))
    }

    @Test("the last words survive when the recognizer leaves them volatile")
    func volatileTailAtEnd() {
        var assembler = TranscriptAssembler()
        assembler.receive(text: "Prima parte.", isFinal: true)
        assembler.receive(text: "seconda parte senza finale", isFinal: false)
        #expect(assembler.text == "Prima parte. seconda parte senza finale")
    }
}

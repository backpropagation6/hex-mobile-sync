import Testing
@testable import HexMobileCore

@Suite("Personal vocabulary respell")
struct PersonalVocabularyTests {
    @Test("A term takes its own spelling, ignoring case")
    func canonicalCase() {
        let result = PersonalVocabulary.respell("ho scritto a mauro dal mio iphone", terms: ["Mauro", "iPhone"])
        #expect(result.text == "ho scritto a Mauro dal mio iPhone")
        #expect(result.changes == 2)
    }

    @Test("A sentence-start capital is not a change when the term is capitalized")
    func alreadyRight() {
        let result = PersonalVocabulary.respell("Mauro conferma la demo.", terms: ["Mauro"])
        #expect(result.text == "Mauro conferma la demo.")
        #expect(result.changes == 0)
    }

    @Test("Only whole words match")
    func wholeWord() {
        let result = PersonalVocabulary.respell("Mauroni e mauro, mauro2 e smauro", terms: ["Mauro"])
        #expect(result.text == "Mauroni e Mauro, mauro2 e smauro")
        #expect(result.changes == 1)
    }

    @Test("Apostrophes and hyphens are word edges")
    func edges() {
        let result = PersonalVocabulary.respell("l'iphone e iphone-based", terms: ["iPhone"])
        #expect(result.text == "l'iPhone e iPhone-based")
        #expect(result.changes == 2)
    }

    @Test("Multi-word terms match across ordinary spaces")
    func multiWord() {
        let result = PersonalVocabulary.respell("uso claude code ogni giorno", terms: ["Claude Code"])
        #expect(result.text == "uso Claude Code ogni giorno")
    }

    @Test("The longer term is applied first")
    func longestFirst() {
        let result = PersonalVocabulary.respell("claude code e claude", terms: ["Claude", "Claude Code"])
        #expect(result.text == "Claude Code e Claude")
        #expect(result.changes == 2)
    }

    @Test("Terms without case information change nothing")
    func lowercaseTermsOnlyBias() {
        let result = PersonalVocabulary.respell("Hex funziona", terms: ["hex"])
        #expect(result.text == "Hex funziona")
        #expect(result.changes == 0)
    }

    @Test("Letters are never changed, only their case")
    func neverChangesLetters() {
        let result = PersonalVocabulary.respell("ho visto marco ieri", terms: ["Mauro"])
        #expect(result.text == "ho visto marco ieri")
    }

    @Test("Accented terms match their own accents only")
    func diacritics() {
        let result = PersonalVocabulary.respell("perché e perche", terms: ["PERCHÉ"])
        #expect(result.text == "PERCHÉ e perche")
        #expect(result.changes == 1)
    }

    @Test("One-letter and blank terms are ignored, the call is idempotent")
    func degenerateTerms() {
        let once = PersonalVocabulary.respell("a e io", terms: ["A", "", "  ", "IO"])
        #expect(once.text == "a e IO")
        let twice = PersonalVocabulary.respell(once.text, terms: ["A", "", "  ", "IO"])
        #expect(twice.text == once.text)
        #expect(twice.changes == 0)
    }

    @Test("No terms or no text is a no-op")
    func noop() {
        #expect(PersonalVocabulary.respell("ciao", terms: []).text == "ciao")
        #expect(PersonalVocabulary.respell("", terms: ["Mauro"]).text == "")
    }
}

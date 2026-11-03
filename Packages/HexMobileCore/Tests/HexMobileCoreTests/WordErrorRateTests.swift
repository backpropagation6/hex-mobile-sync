import Foundation
import Testing
@testable import HexMobileCore

@Suite("Word error rate")
struct WordErrorRateTests {
    @Test("Case and punctuation do not count")
    func normalization() {
        let score = WordErrorRate.score(reference: "Ciao, Mauro! Come stai?", hypothesis: "ciao mauro come stai")
        #expect(score.errors == 0)
        #expect(score.rate == 0)
        #expect(score.referenceWords == 4)
    }

    @Test("Apostrophes and hyphens split words on both sides")
    func apostrophe() {
        #expect(WordErrorRate.score(reference: "l'altro giorno", hypothesis: "l altro giorno").errors == 0)
        #expect(WordErrorRate.words(in: "dall'iPhone-based") == ["dall", "iphone", "based"])
    }

    @Test("Accents do count")
    func accents() {
        let score = WordErrorRate.score(reference: "perché no", hypothesis: "perche no")
        #expect(score.substitutions == 1)
        #expect(score.rate == 0.5)
    }

    @Test("Substitutions, deletions and insertions are told apart")
    func kinds() {
        let sub = WordErrorRate.score(reference: "sta funzionando bene", hypothesis: "sta rompendo bene")
        #expect((sub.substitutions, sub.deletions, sub.insertions) == (1, 0, 0))
        let del = WordErrorRate.score(reference: "una due tre", hypothesis: "una tre")
        #expect((del.substitutions, del.deletions, del.insertions) == (0, 1, 0))
        let ins = WordErrorRate.score(reference: "una tre", hypothesis: "una due tre")
        #expect((ins.substitutions, ins.deletions, ins.insertions) == (0, 0, 1))
    }

    @Test("Empty sides")
    func empties() {
        #expect(WordErrorRate.score(reference: "", hypothesis: "boh").rate == nil)
        #expect(WordErrorRate.score(reference: "", hypothesis: "boh").insertions == 1)
        let lost = WordErrorRate.score(reference: "uno due", hypothesis: "")
        #expect(lost.deletions == 2)
        #expect(lost.rate == 1)
    }

    @Test("The corpus rate weighs clips by their length")
    func corpus() {
        let a = WordErrorRate.score(reference: "a b c d", hypothesis: "a b c x")      // 1 / 4
        let b = WordErrorRate.score(reference: "a b", hypothesis: "a b")               // 0 / 2
        #expect(WordErrorRate.corpusRate([a, b]) == 1.0 / 6.0)
        #expect(WordErrorRate.corpusRate([]) == nil)
    }

    @Test("A reference file as JSON")
    func referenceJSON() throws {
        let data = Data(#"{"s01.caf": "Ciao.", "s02": "Come stai?"}"#.utf8)
        #expect(try ReferenceFile.parse(data) == ["s01": "Ciao.", "s02": "Come stai?"])
    }

    @Test("A reference file as tab-separated lines")
    func referenceTSV() throws {
        let text = "# comment\ns01\tCiao.\n\ns02.caf\tCome stai?\nbroken line\n"
        #expect(try ReferenceFile.parse(Data(text.utf8)) == ["s01": "Ciao.", "s02": "Come stai?"])
    }
}

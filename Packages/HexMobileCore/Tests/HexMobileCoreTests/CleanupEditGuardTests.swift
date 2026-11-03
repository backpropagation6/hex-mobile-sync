import Foundation
import Testing
@testable import HexMobileCore

@Suite("Cleanup edit guard")
struct CleanupEditGuardTests {
    private func verdict(_ input: String, _ output: String) -> CleanupGuard.Verdict {
        CleanupGuard.check(input: input, output: output)
    }

    /// The alignment alone, without the outer net of length and bag of words
    /// (the rules are tested on short phrases that the net would refuse for
    /// their length).
    private func allows(_ input: String, _ output: String) -> Bool {
        CleanupEditGuard.violation(input: input, output: output) == nil
    }

    // MARK: The examples of the prompt

    /// The (dictation, output) pairs written in the instructions of the prompt.
    private func promptExamples() -> [(String, String)] {
        let lines = CleanupPrompt.instructions(languageName: "italiano").components(separatedBy: "\n")
        var examples: [(String, String)] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("<\(CleanupPrompt.tag)>") && index + 1 < lines.count {
            examples.append((CleanupPrompt.stripTags(line), lines[index + 1]))
        }
        return examples
    }

    @Test("the three examples of the prompt are accepted")
    func promptExamplesAccepted() {
        let examples = promptExamples()
        #expect(examples.count == 3)
        for (input, output) in examples {
            #expect(verdict(input, output) == .accept(output), "\(input) -> \(output)")
        }
    }

    // MARK: Recorded cleanups (synthetic phrases dictated on 2 Nov 2026)

    private struct Pair: Decodable {
        var name: String
        var input: String
        var output: String
        var expected: String
    }

    @Test("recorded cleanups: punctuation passes, a deleted or respelled word does not")
    func recorded() throws {
        let pairs = try JSONDecoder().decode([Pair].self, from: fixtureData("cleanup-phone-b10"))
        #expect(pairs.count == 26)
        for pair in pairs {
            let result = verdict(pair.input, pair.output)
            switch pair.expected {
            case "accept": #expect(result == .accept(pair.output), "\(pair.name)")
            default: #expect(result == .reject(.edited), "\(pair.name)")
            }
        }
        // The three losses of the phone: «bene o male», three «di» and «ed è» -> «e è».
        let rejected = Set(pairs.filter { $0.expected != "accept" }.map(\.name))
        #expect(rejected.contains("s10-vocab"))
        #expect(rejected.contains("long02-vocab"))
        #expect(rejected.contains("long02-novocab"))
    }

    @Test("what each recorded loss was")
    func recordedViolations() throws {
        let pairs = try JSONDecoder().decode([Pair].self, from: fixtureData("cleanup-phone-b10"))
        let s10 = try #require(pairs.first { $0.name == "s10-vocab" })
        let violation = try #require(CleanupEditGuard.violation(input: s10.input, output: s10.output))
        #expect(violation.removed == 3)
        #expect(violation.added == 0)
        let long02 = try #require(pairs.first { $0.name == "long02-vocab" })
        // Four dictated words go: the three «di» and the «ed» that became «e».
        let loss = try #require(CleanupEditGuard.violation(input: long02.input, output: long02.output))
        #expect(loss.removed >= 3)
    }

    // MARK: Rejected

    @Test("a word taken out without a rule is an edit")
    func deletion() {
        let input = "sta andando proprio alla grande perché comunque bene o male il sistema funziona"
        #expect(verdict(input, "Sta andando proprio alla grande, perché comunque il sistema funziona.") == .reject(.edited))
        #expect(verdict("devo ricordarmi di inviare la bozza e di verificare le scadenze con il commercialista", "Devo ricordarmi di inviare la bozza e verificare le scadenze con il commercialista.") == .reject(.edited))
    }

    @Test("a word added that was not dictated is an edit")
    func insertion() {
        let input = "domani mattina devo chiamare il commercialista per la dichiarazione dei redditi"
        let output = "Domani mattina devo assolutamente chiamare il commercialista per la dichiarazione dei redditi."
        #expect(verdict(input, output) == .reject(.edited))
        let violation = CleanupEditGuard.violation(input: input, output: output)
        #expect(violation?.added == 1)
        #expect(violation?.removed == 0)
    }

    @Test("a word replaced is an edit, a word moved is an edit")
    func replacement() {
        let input = "il deploy su vercell è andato a buon fine ma la pipeline ha dato un errore"
        #expect(verdict(input, "Il deploy su Vercelli è andato a buon fine, ma la pipeline ha dato un errore.") == .reject(.edited))
        #expect(verdict("ci vediamo domani mattina alle dieci in ufficio da me", "Ci vediamo alle dieci domani mattina in ufficio da me.") == .reject(.edited))
        // Same length and words, one conjunction turned into another.
        #expect(verdict("ho chiamato il cliente e ho mandato il preventivo", "Ho chiamato il cliente, ma ho mandato il preventivo.") == .reject(.edited))
    }

    @Test("«ed» turned into «e» is an edit")
    func conjunction() {
        let input = "questo è l'ultimo punto della lista ed è qui che finisce la registrazione"
        #expect(verdict(input, "Questo è l'ultimo punto della lista e è qui che finisce la registrazione.") == .reject(.edited))
    }

    @Test("words before the marker beyond the window, or after it, stay")
    func retractionLimits() {
        // Nine words before «no anzi»: only the last eight may go.
        let input = "ti scrivo per dirti che la riunione di giovedì è spostata no anzi a lunedì pomeriggio"
        let output = "Ti scrivo a lunedì pomeriggio."
        #expect(!allows(input, output))
        #expect(CleanupEditGuard.violation(input: input, output: output, maximumRetractedWords: 20) == nil)
        // Eight words go.
        #expect(allows("ti scrivo che la riunione di giovedì è spostata no anzi a lunedì pomeriggio", "Ti scrivo a lunedì pomeriggio."))
        // Words after the marker are never retracted.
        #expect(!allows("ci vediamo martedì no anzi mercoledì alle dieci in ufficio", "Ci vediamo martedì, no anzi mercoledì."))
        // A word kept between the deleted one and the marker is not "right before".
        #expect(!allows("allora sono arrivato ieri sera tardi e anzi stamattina sono ripartito", "Allora sono arrivato tardi e anzi stamattina sono ripartito."))
        // The marker without a retraction before it, but not a word elsewhere.
        #expect(allows("allora ci vediamo anzi no domani", "Allora ci vediamo no domani."))
        #expect(!allows("allora ci vediamo anzi no domani", "Allora ci vediamo anzi domani."))
    }

    @Test("a text too long to align is not accepted")
    func tooLongToAlign() {
        let long = Array(repeating: "parola", count: 1_100).joined(separator: " ")
        #expect(CleanupEditGuard.violation(input: long, output: long) != nil)
    }

    // MARK: Accepted

    @Test("hesitations, a repetition and a retracted phrase go; case, accents and punctuation change")
    func allowed() {
        #expect(allows("ehm allora ci vediamo domani no anzi dopodomani alle tre", "Allora ci vediamo dopodomani alle tre."))
        #expect(allows("mi mi serve il il preventivo entro venerdì ok", "Mi serve il preventivo entro venerdì, ok."))
        #expect(allows("uhm sì eh certo mmm ci sono", "Sì, certo, ci sono."))
        // Accent on one side only.
        #expect(allows("e perche no", "E perché no?"))
        #expect(allows("Perché NO", "Perché no."))
    }

    @Test("a repeated phrase and a repeated word at the other side of the kept one")
    func repetitions() {
        #expect(allows("il mio il mio cane è qui", "Il mio cane è qui."))
        #expect(allows("il cane cane è qui", "Il cane è qui."))
        #expect(allows("ci vediamo ci vediamo domani alle tre", "Ci vediamo domani alle tre."))
        // Three copies.
        #expect(allows("non non non lo so", "Non lo so."))
    }

    @Test("a retraction whose kept words repeat the retracted ones")
    func retractionWithSharedWords() {
        // Which «domani alle» the alignment keeps does not change the verdict.
        #expect(allows("ci vediamo domani alle tre no anzi domani alle quattro", "Ci vediamo domani alle quattro."))
        #expect(allows("ci vediamo domani alle tre scusa intendevo dopodomani alle quattro", "Ci vediamo dopodomani alle quattro."))
        #expect(allows("passo da te lunedì volevo dire martedì mattina", "Passo da te martedì mattina."))
        #expect(allows("ho mandato il preventivo a marco anzi a mauro ieri", "Ho mandato il preventivo a mauro ieri."))
    }

    @Test("numbers written as digits or as words are the same word")
    func numbers() {
        #expect(allows("ci vediamo alle tre di giovedì", "Ci vediamo alle 3 di giovedì."))
        #expect(allows("ho pagato venticinque euro", "Ho pagato 25 euro."))
        #expect(allows("siamo nel duemilaventisei", "Siamo nel 2026."))
        #expect(allows("ci sono 12 ospiti", "Ci sono dodici ospiti."))
        #expect(allows("sono quarantatré anni", "Sono 43 anni."))
        // A different number is an edit.
        #expect(!allows("ci vediamo alle tre di giovedì", "Ci vediamo alle 4 di giovedì."))
        #expect(!allows("ci vediamo alle tre di giovedì", "Ci vediamo alle di giovedì."))
    }

    @Test("a retraction with a number spelled the other way")
    func retractionAndNumbers() {
        #expect(allows("ci vediamo alle tre no anzi alle quattro", "Ci vediamo alle 4."))
    }

    // MARK: Italian numbers

    @Test("Italian numbers in words and digits")
    func italianNumbers() {
        let cases: [([String], Int)] = [
            (["zero"], 0), (["uno"], 1), (["tre"], 3), (["tredici"], 13), (["venti"], 20),
            (["ventuno"], 21), (["ventotto"], 28), (["trentatre"], 33), (["quarantasei"], 46),
            (["cento"], 100), (["centotto"], 108), (["centoventi"], 120), (["duecentocinquanta"], 250),
            (["mille"], 1_000), (["milleduecento"], 1_200), (["duemila"], 2_000),
            (["duemilaventisei"], 2_026), (["centomila"], 100_000), (["un", "milione"], 1_000_000),
            (["venti", "e", "sei"], 26), (["mille", "e", "uno"], 1_001),
            (["2026"], 2_026), (["2", "026"], 2_026), (["007"], 7),
        ]
        for (tokens, value) in cases {
            #expect(ItalianNumber.value(of: tokens) == value, "\(tokens)")
        }
        // Not numbers, or not well formed.
        for tokens in [["casa"], ["tredue"], ["tre", "due"], ["ventotre", "venti"], ["mila"], ["cento", "cento"], ["zero", "uno"], ["2", "26"], []] as [[String]] {
            #expect(ItalianNumber.value(of: tokens) == nil, "\(tokens)")
        }
    }

    @Test("a run of number words becomes its digits, an article stays")
    func normalizeNumbers() {
        #expect(ItalianNumber.normalize(["alle", "venti", "cinque", "euro"]) == ["alle", "25", "euro"])
        #expect(ItalianNumber.normalize(["tre", "due"]) == ["3", "2"])
        #expect(ItalianNumber.normalize(["tre", "e", "due"]) == ["3", "e", "2"])
        #expect(ItalianNumber.normalize(["un", "amico"]) == ["un", "amico"])
        #expect(ItalianNumber.normalize(["un", "milione", "di", "euro"]) == ["1000000", "di", "euro"])
        #expect(ItalianNumber.normalize(["2", "026"]) == ["2026"])
        #expect(ItalianNumber.normalize(["mille", "e", "uno"]) == ["1001"])
        #expect(ItalianNumber.normalize(["il", "sei", "ottobre", "alle", "3", "e", "30"]) == ["il", "6", "ottobre", "alle", "3", "e", "30"])
        #expect(ItalianNumber.normalize(["venti", "e"]) == ["20", "e"])
    }
}

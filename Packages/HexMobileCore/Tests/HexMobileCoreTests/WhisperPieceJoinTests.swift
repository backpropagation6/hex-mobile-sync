import Foundation
import Testing
@testable import HexMobileCore

@Suite("Whisper pieces joined")
struct WhisperPieceJoinTests {
    @Test("a piece after a comma continues the sentence: its capital goes down")
    func afterComma() {
        let joined = WhisperClips.join(["Ho riascoltato le registrazioni,", " Perché mancava una frase."], language: "it")
        #expect(joined.text == "Ho riascoltato le registrazioni, perché mancava una frase.")
        #expect(joined.lowercased == 1)
        #expect(joined.pieces == 2)
        #expect(joined.logLine == "whisper join pieces=2 lowercased=1")
    }

    @Test("after a word with no punctuation, a semicolon or a colon too")
    func afterNothing() {
        #expect(WhisperClips.join(["Gli ho scritto la mail", " Con tutti i dettagli"]).text == "Gli ho scritto la mail con tutti i dettagli")
        #expect(WhisperClips.join(["Vado a Milano;", " Poi torno"]).text == "Vado a Milano; poi torno")
        #expect(WhisperClips.join(["Ti dico una cosa:", " Non serve"]).text == "Ti dico una cosa: non serve")
    }

    @Test("after the end of a sentence the capital stays, with a closing quote or bracket looked through")
    func afterSentenceEnd() {
        #expect(WhisperClips.join(["Finito.", " Ora il resto"]).text == "Finito. Ora il resto")
        #expect(WhisperClips.join(["Davvero?", " Sì"]).text == "Davvero? Sì")
        #expect(WhisperClips.join(["Basta!", " Adesso"]).text == "Basta! Adesso")
        #expect(WhisperClips.join(["E poi…", " Niente"]).text == "E poi… Niente")
        #expect(WhisperClips.join(["Ha detto «vieni».", " Sono andato"]).text == "Ha detto «vieni». Sono andato")
        #expect(WhisperClips.join(["(come sempre.)", " Ora"]).text == "(come sempre.) Ora")
        let joined = WhisperClips.join(["Fine.", " Inizio"])
        #expect(joined.lowercased == 0)
    }

    @Test("the first piece is never touched, and a single piece comes back as it is")
    func firstPiece() {
        #expect(WhisperClips.join(["  Ciao a tutti  "]).text == "Ciao a tutti")
        #expect(WhisperClips.join(["Prima,", " seconda"]).lowercased == 0)
        #expect(WhisperClips.join([]).text.isEmpty)
        #expect(WhisperClips.join(["", "  "]).pieces == 0)
    }

    @Test("empty pieces are skipped without breaking the rule")
    func emptyPieces() {
        let joined = WhisperClips.join(["Ho scelto,", "  ", " Perché sì"])
        #expect(joined.text == "Ho scelto, perché sì")
        #expect(joined.pieces == 2)
    }

    @Test("pieces are put together as the decoder wrote them: nothing is added")
    func nothingAdded() {
        // A cut inside a word that the model continues with no space stays one word.
        #expect(WhisperClips.join(["Le infor", "mazioni"]).text == "Le informazioni")
        // A text of a window that does not begin with a space is not given one.
        #expect(WhisperClips.join(["Vado,", "Poi torno"]).text == "Vado,poi torno")
    }

    @Test("acronyms and words with more than one capital stay")
    func capitals() {
        #expect(WhisperClips.join(["Lo pago con", " IBAN diverso"]).text == "Lo pago con IBAN diverso")
        #expect(WhisperClips.join(["Ho allenato,", " LoRA sul modello"]).text == "Ho allenato, LoRA sul modello")
        #expect(WhisperClips.join(["Ho parlato con", " Dell'Orto ieri"]).text == "Ho parlato con Dell'Orto ieri")
    }

    @Test("an apostrophe or an accent does not stop the lowering; a quote or a bracket at the start does")
    func apostropheAccentQuote() {
        #expect(WhisperClips.join(["Ho visto", " L'amico di Mauro"]).text == "Ho visto l'amico di Mauro")
        #expect(WhisperClips.join(["Era tardi,", " È stato difficile"]).text == "Era tardi, è stato difficile")
        #expect(WhisperClips.join(["Ha detto,", " «Vieni qui»"]).text == "Ha detto, «Vieni qui»")
        #expect(WhisperClips.join(["Ha detto,", " (Vieni qui)"]).text == "Ha detto, (Vieni qui)")
        #expect(WhisperClips.join(["Nel 2026,", " 12 persone"]).text == "Nel 2026, 12 persone")
    }

    @Test("the article «I» is lowercased in Italian only")
    func englishI() {
        #expect(WhisperClips.join(["Ho sentito,", " I clienti sono tre"], language: "it").text == "Ho sentito, i clienti sono tre")
        #expect(WhisperClips.join(["Then,", " I think so"], language: "en").text == "Then, I think so")
        #expect(WhisperClips.join(["Then,", " I'm sure"], language: "en").text == "Then, I'm sure")
        #expect(WhisperClips.join(["Then,", " I think so"], language: nil).text == "Then, I think so")
    }

    @Test("a user's term lowered at a join gets its spelling back from the respell")
    func respellRestoresTerms() {
        let joined = WhisperClips.join(["Ho scritto a Zentrix e poi ho chiamato", " Mauro Rossi per il resto,", " Mauro ha risposto"], language: "it")
        // Both «Mauro» open a piece that continues the sentence: both go down.
        #expect(joined.text == "Ho scritto a Zentrix e poi ho chiamato mauro Rossi per il resto, mauro ha risposto")
        #expect(joined.lowercased == 2)
        let restored = PersonalVocabulary.respell(joined.text, terms: ["Mauro", "Zentrix"])
        #expect(restored.text == "Ho scritto a Zentrix e poi ho chiamato Mauro Rossi per il resto, Mauro ha risposto")
        #expect(restored.changes == 2)
    }

    @Test("a proper name that is not a term is lowered: the cost of the rule, said here")
    func unknownNameIsLowered() {
        let joined = WhisperClips.join(["Sono andato a trovarlo,", " Bergamo era deserta"], language: "it")
        #expect(joined.text == "Sono andato a trovarlo, bergamo era deserta")
        #expect(PersonalVocabulary.respell(joined.text, terms: ["Mauro"]).text == joined.text)
    }

    @Test("the text starts with a capital, as a sentence does")
    func firstCapital() {
        // s10 with the vocabulary, 2 Nov 2026: «sta andando…», the prompt ends with a comma.
        #expect(WhisperClips.join([" sta andando proprio alla grande, perché comunque il sistema funziona."], language: "it").text
            == "Sta andando proprio alla grande, perché comunque il sistema funziona.")
        #expect(WhisperClips.join(["ho riascoltato,", " Perché mancava una frase."], language: "it").text
            == "Ho riascoltato, perché mancava una frase.")
        // With an apostrophe or an accent at the start.
        #expect(WhisperClips.join(["l'ufficio è chiuso"]).text == "L'ufficio è chiuso")
        #expect(WhisperClips.join(["è tardi"]).text == "È tardi")
    }

    @Test("a first word that has a capital inside, a digit, a quote, a bracket or a symbol stays")
    func firstCapitalKeeps() {
        #expect(WhisperClips.join(["«sì, vengo»"]).text == "«sì, vengo»")
        #expect(WhisperClips.join(["(come sempre) torno"]).text == "(come sempre) torno")
        #expect(WhisperClips.join(["iPhone nuovo"]).text == "iPhone nuovo")
        #expect(WhisperClips.join(["eBay è sceso"]).text == "eBay è sceso")
        #expect(WhisperClips.join(["12 persone"]).text == "12 persone")
        #expect(WhisperClips.join(["Già così"]).text == "Già così")
        #expect(WhisperClips.join(["… e poi"]).text == "… e poi")
        #expect(WhisperClips.capitalizingFirstLetter("") == "")
        #expect(WhisperClips.capitalizingFirstLetter("  ") == "  ")
    }
}

import Foundation
import Testing
@testable import HexMobileCore

/// The texts are the synthetic clip `long01` (a `say` voice reading a script of
/// ours, never a real dictation), as recorded on the phone on 2 Nov 2026.
private enum Long01 {
    /// What was said.
    static let reference = "Oggi ho passato la mattina a rivedere il flusso di dettatura dell'applicazione. Il primo problema è che il testo arriva senza punteggiatura e con le maiuscole nei posti sbagliati, quindi lo devo correggere a mano ogni volta. Il secondo problema è che il riconoscitore veloce sbaglia alcune parole, soprattutto i nomi propri e i termini tecnici. Per questo vorrei fare un secondo passaggio sull'audio registrato, con il modello più accurato, e poi pulire il testo con il modello di linguaggio che sta sul telefono. Alla fine voglio misurare quanto migliora davvero, confrontando le varianti sulle stesse registrazioni, perché senza numeri è facile raccontarsi una storia comoda. Se il risultato è buono lo lascio attivo, altrimenti torno indietro e provo un'altra strada."

    /// Apple's accurate pass on the phone (760 characters, complete, a few small differences).
    static let apple = "Oggi ho passato la mattina a rivedere il flusso di dettatura dell'applicazione. Il primo problema è che il testo arriva senza punteggiatura e con le maiuscole nei posti sbagliati, quindi lo devo correggere a mano ogni volta. Il secondo problema è che il riconoscitore veloce sbaglia alcune parole, soprattutto i nomi propri e termini tecnici. Per questo vorrei fare un secondo passaggio sull'audio registrato con il modello più accurato e poi pulire il testo con il modello di linguaggio che sta sul telefono. Alla fine voglio misurare quanto migliora davvero confrontando le varianti sulle stesse registrazioni, perché senza numeri è facile raccontarsi una storia comoda. Se il risultato è buono lo lascio attivo, altrimenti torno indietro e provo un'altra strada."

    /// Whisper without the prompt (728 characters): «Alla fine voglio misurare quanto migliora» is missing.
    static let whisperWithoutPrompt = "Oggi ho passato la mattina a rivedere il flusso di dettatura dell'applicazione. Il primo problema è che il testo arriva senza punteggiatura e con le maiuscole nei posti sbagliati, quindi lo devo correggere a mano ogni volta. Il secondo problema è che il riconoscitore veloce sbaglia alcune parole, soprattutto i nomi propri e i termini tecnici. Per questo vorrei fare un secondo passaggio sull'audio registrato, con il modello più accurato, e poi pulire il testo con il modello di linguaggio che sta sul telefono. davvero, confrontando le varianti sulle stesse registrazioni, perché senza numeri è facile raccontarsi una storia comoda, se il risultato è buono lo lascio attivo, altrimenti torno indietro e provo un'altra strada."

    /// Whisper with the 32-term prompt (626 characters): from «con il modello più accurato» to «quanto migliora» is missing.
    static let whisperWithPrompt = "Oggi ho passato la mattina a rivedere il flusso di dettatura dell'applicazione. Il primo problema è che il testo arriva senza punteggiatura e con le maiuscole nei posti sbagliati, quindi lo devo correggere a mano ogni volta. Il secondo problema è che il riconoscitore veloce sbaglia alcune parole, soprattutto i nomi propri e i termini tecnici. Per questo vorrei fare un secondo passaggio sull'audio registrato, davvero, confrontando le varianti sulle stesse registrazioni, perché senza numeri è facile raccontarsi una storia comoda, se il risultato è buono lo lascio attivo, altrimenti torno indietro e provo un'altra strada."

    /// Whisper in pieces on the Mac: complete.
    static let whisperInPieces = "Oggi ho passato la mattina a rivedere il flusso di dettatura dell'applicazione. Il primo problema è che il testo arriva senza punteggiatura e con le maiuscole nei posti sbagliati, quindi lo devo correggere a mano ogni volta. Il secondo problema è che il riconoscitore veloce sbaglia alcune parole, soprattutto i nomi propri e i termini tecnici. Per questo vorrei fare un secondo passaggio sull'audio registrato, con il modello più accurato, e poi pulire il testo con il modello di linguaggio che sta sul telefono. Alla fine voglio misurare quanto migliora davvero, confrontando le varianti sulle stesse registrazioni, Perché senza numeri è facile raccontarsi una storia comoda, se il risultato è buono lo lascio attivo, altrimenti torno indietro e provo un'altra strada."
}

@Suite("Transcript gap guard")
struct TranscriptGapGuardTests {
    private func index(of word: String, in text: String) -> Int {
        WordErrorRate.words(in: text).firstIndex(of: word) ?? -1
    }

    @Test("the length rule does not see the lost sentence of 2 Nov 2026, the gap does")
    func lostSentence() throws {
        // 728 of 760 characters, and the word count is far above half: the old guard says yes.
        #expect(FinalPassPolicy.decide(live: Long01.apple, final: Long01.whisperWithoutPrompt) == .useFinal)
        let gap = try #require(TranscriptGapGuard.findGap(reference: Long01.apple, candidate: Long01.whisperWithoutPrompt))
        // «Alla fine voglio misurare quanto migliora»: six words, from «alla».
        #expect(gap.missing == 6)
        #expect(gap.at == index(of: "alla", in: Long01.apple))
    }

    @Test("a long loss is found at its start")
    func longLoss() throws {
        #expect(FinalPassPolicy.decide(live: Long01.apple, final: Long01.whisperWithPrompt) == .useFinal)
        let gap = try #require(TranscriptGapGuard.findGap(reference: Long01.apple, candidate: Long01.whisperWithPrompt))
        // From «con il modello più accurato…» (right after «registrato») to «quanto migliora»: 25 words.
        #expect(gap.missing == 25)
        #expect(gap.at == index(of: "registrato", in: Long01.apple) + 1)
        let words = WordErrorRate.words(in: Long01.apple)
        #expect(words[gap.at ..< gap.at + gap.missing].contains("migliora"))
    }

    @Test("the same against the right text: the reference finds the same losses")
    func againstReference() {
        #expect(TranscriptGapGuard.findGap(reference: Long01.reference, candidate: Long01.whisperWithoutPrompt)?.missing == 6)
        #expect(TranscriptGapGuard.findGap(reference: Long01.reference, candidate: Long01.whisperWithPrompt) != nil)
    }

    @Test("a complete text is accepted, whatever its small differences")
    func completeText() {
        #expect(TranscriptGapGuard.findGap(reference: Long01.apple, candidate: Long01.whisperInPieces) == nil)
        #expect(TranscriptGapGuard.largestGap(reference: Long01.apple, candidate: Long01.whisperInPieces) == nil)
        #expect(TranscriptGapGuard.findGap(reference: Long01.apple, candidate: Long01.reference) == nil)
        #expect(TranscriptGapGuard.findGap(reference: Long01.apple, candidate: Long01.apple) == nil)
    }

    @Test("a name spelled another way, a number written out, a spelling: substitutions, not gaps")
    func substitutions() {
        let reference = "Il deploy su Vercelli è andato bene il 21 novembre alle 10 e la pipeline di Seni ti non ha dato errori"
        let candidate = "Il deploy su Vercel è andato bene il ventuno novembre alle dieci e la pipeline di Sanity non ha dato errori"
        // «Seni ti» for «Sanity» leaves one word with no counterpart, nothing else does.
        #expect(TranscriptGapGuard.largestGap(reference: reference, candidate: candidate)?.missing == 1)
        #expect(TranscriptGapGuard.findGap(reference: reference, candidate: candidate) == nil)
        // Five words replaced by two: three are gone, no more.
        let shorter = TranscriptGapGuard.largestGap(reference: "uno due tre quattro cinque sei", candidate: "uno ics sei")
        #expect(shorter?.missing == 3)
    }

    @Test("case, punctuation and apostrophes do not matter; an accent does")
    func normalization() {
        #expect(TranscriptGapGuard.largestGap(reference: "Sì, certo! Dell'altro giorno.", candidate: "sì certo dell altro giorno") == nil)
        // «perché» for «perche» is a substitution, one word: still no gap.
        #expect(TranscriptGapGuard.largestGap(reference: "perché no", candidate: "perche no") == nil)
    }

    @Test("the run needed is the caller's: four lost words pass at five, not at four")
    func threshold() {
        let reference = "uno due tre quattro cinque sei sette otto nove dieci"
        let candidate = "uno due tre sette otto nove dieci"
        #expect(TranscriptGapGuard.largestGap(reference: reference, candidate: candidate) == TranscriptGapGuard.Gap(missing: 3, at: 3))
        let four = "uno due tre otto nove dieci"
        #expect(TranscriptGapGuard.largestGap(reference: reference, candidate: four)?.missing == 4)
        #expect(TranscriptGapGuard.findGap(reference: reference, candidate: four) == nil)
        #expect(TranscriptGapGuard.findGap(reference: reference, candidate: four, minimumRun: 4)?.missing == 4)
        #expect(TranscriptGapGuard.findGap(reference: reference, candidate: "uno due tre dieci")?.missing == 6)
    }

    @Test("words lost in two places are not added up")
    func separateLosses() {
        let reference = "a1 b2 c3 d4 e5 f6 g7 h8 i9 j10 k11 l12"
        // Lost: b2 c3 d4 (3) and i9 j10 (2): two small gaps, none reaches five.
        let candidate = "a1 e5 f6 g7 h8 k11 l12"
        #expect(TranscriptGapGuard.largestGap(reference: reference, candidate: candidate)?.missing == 3)
        #expect(TranscriptGapGuard.findGap(reference: reference, candidate: candidate) == nil)
    }

    @Test("the end of the text lost is a gap too")
    func lostEnd() {
        let gap = TranscriptGapGuard.largestGap(
            reference: "uno due tre quattro cinque sei sette otto",
            candidate: "uno due tre quattro"
        )
        #expect(gap == TranscriptGapGuard.Gap(missing: 4, at: 4))
    }

    @Test("empty sides")
    func empties() {
        #expect(TranscriptGapGuard.largestGap(reference: "", candidate: "boh") == nil)
        #expect(TranscriptGapGuard.largestGap(reference: "uno due tre quattro cinque", candidate: "") == TranscriptGapGuard.Gap(missing: 5, at: 0))
        #expect(TranscriptGapGuard.findGap(reference: "uno due", candidate: "") == nil)
    }

    @Test("Apple hallucinating five words refuses a correct Whisper text: conservative, Apple's text stays")
    func appleExtraWords() {
        let apple = "Ho chiamato Mauro per il preventivo ehm allora cioè praticamente sì e poi gli ho scritto"
        let whisper = "Ho chiamato Mauro per il preventivo e poi gli ho scritto"
        let gap = TranscriptGapGuard.findGap(reference: apple, candidate: whisper)
        #expect(gap?.missing == 5)
        #expect(gap?.at == 6)
    }

    @Test("texts too long to align are not judged, and the verdict says so")
    func tooLong() {
        let long = (0..<1200).map { "parola\($0)" }.joined(separator: " ")
        let other = (0..<900).map { "altra\($0)" }.joined(separator: " ")
        #expect(TranscriptGapGuard.largestGap(reference: long, candidate: other) == nil)
        #expect(TranscriptGapGuard.findGap(reference: long, candidate: other) == nil)
        // Not the same as "no gap": the caller logs it.
        #expect(TranscriptGapGuard.judge(reference: long, candidate: other) == .notJudged(cells: 1201 * 901))
        #expect(TranscriptGapGuard.judge(reference: "uno due", candidate: "uno due") == .accepted)
    }

    // MARK: - Batch 10: the review's cases

    @Test("(a) nine words lost and five others in their place: refused, the net rule alone passes it")
    func lossCoveredByInventedWords() throws {
        let reference = "ho incontrato Marco alle nove del mattino nella sala riunioni del piano e poi siamo andati a pranzo"
        let candidate = "ho incontrato Marco sottotitoli creati dalla comunità amara e poi siamo andati a pranzo"
        // 9 words of the reference with no counterpart, 5 written: net 4, below the run of five.
        let gap = try #require(TranscriptGapGuard.largestGap(reference: reference, candidate: candidate))
        #expect(gap == TranscriptGapGuard.Gap(missing: 4, at: 3, written: 5, unmatched: 9))
        #expect(gap.missing < TranscriptGapGuard.defaultMinimumRun)
        #expect(TranscriptGapGuard.judge(reference: reference, candidate: candidate) == .refused(gap))
        // The same at the end of the text, where Whisper hallucinates into the silence of a piece.
        let tail = TranscriptGapGuard.findGap(
            reference: "poi ho chiuso il ticket e ho scritto al cliente per dirgli che era tutto a posto",
            candidate: "poi ho chiuso il ticket e ho scritto sottotitoli creati dalla comunità amara org"
        )
        #expect(tail != nil)
        #expect(tail?.missing == 3)
        #expect(tail?.unmatched == 9)
    }

    @Test("(b) a loss of five words with an isolated «il» that the aligner takes as an anchor: refused")
    func lossSplitByShortAnchor() throws {
        // Lost: «poi il cliente ha chiesto»; the candidate's «il» pairs with the first «il».
        let reference = "ho sentito Marco e poi il cliente ha chiesto il preventivo per lunedì"
        let candidate = "ho sentito Marco e il preventivo per lunedì"
        let gap = try #require(TranscriptGapGuard.largestGap(reference: reference, candidate: candidate))
        #expect(gap.missing == 5)
        #expect(gap.at == 4)
        #expect(TranscriptGapGuard.findGap(reference: reference, candidate: candidate) != nil)
        // The pieces of seven (two anchors, «di» and «il») are one gap as well.
        let seven = "ho sentito Marco e poi il cliente ha chiesto di nuovo il preventivo di lunedì"
        #expect(TranscriptGapGuard.findGap(reference: seven, candidate: "ho sentito Marco e il preventivo di lunedì") != nil)
    }

    @Test("two matched words in a row are an anchor, and so is a word of three letters")
    func realAnchorsKeepGapsApart() {
        // One short word between two gaps joins them; «il di» (two) or «sul» (three) does not.
        let one = "alfa beta gamma il delta epsilon zeta"
        #expect(TranscriptGapGuard.largestGap(reference: one, candidate: "il")?.missing == 6)
        let two = "alfa beta gamma il di delta epsilon zeta"
        #expect(TranscriptGapGuard.largestGap(reference: two, candidate: "il di")?.missing == 3)
        #expect(TranscriptGapGuard.findGap(reference: two, candidate: "il di") == nil)
        let three = "alfa beta gamma sul delta epsilon zeta"
        #expect(TranscriptGapGuard.largestGap(reference: three, candidate: "sul")?.missing == 3)
    }

    @Test("(c) a rewording with as many words as it replaces is accepted, five by five and nine by nine")
    func rewording() {
        let five = TranscriptGapGuard.largestGap(
            reference: "ci vediamo davanti al bar centrale alle otto",
            candidate: "ci troviamo fuori dal caffè principale alle otto"
        )
        #expect(five?.missing ?? 0 <= 0)
        #expect(TranscriptGapGuard.findGap(
            reference: "ci vediamo davanti al bar centrale alle otto",
            candidate: "ci troviamo fuori dal caffè principale alle otto"
        ) == nil)
        // Nine words each side, none in common: nothing was lost.
        #expect(TranscriptGapGuard.findGap(
            reference: "prima di partire controlla che le chiavi siano nella borsa grande e il biglietto",
            candidate: "prima di partire verifica se hai portato con te lo zaino rosso e il biglietto"
        ) == nil)
    }

    @Test("(d) digits against numbers in letters are substitutions")
    func numbers() {
        #expect(TranscriptGapGuard.findGap(
            reference: "il 3 marzo 2026 abbiamo firmato il contratto",
            candidate: "il tre marzo duemilaventisei abbiamo firmato il contratto"
        ) == nil)
        #expect(TranscriptGapGuard.findGap(
            reference: "il tre marzo duemilaventisei abbiamo firmato il contratto",
            candidate: "il 3 marzo 2026 abbiamo firmato il contratto"
        ) == nil)
        // Two words for one: a net of one, not a gap.
        #expect(TranscriptGapGuard.findGap(
            reference: "nel duemila ventisei lo rifaccio",
            candidate: "nel 2026 lo rifaccio"
        ) == nil)
        #expect(TranscriptGapGuard.findGap(
            reference: "alle 10 e 30 del 21 novembre",
            candidate: "alle dieci e trenta del ventuno novembre"
        ) == nil)
    }

    @Test("(e) the two cut texts of 2 Nov 2026 are refused, with both counts, and the whole one is accepted")
    func theTwoLossesOfTheDay() throws {
        guard case let .refused(without) = TranscriptGapGuard.judge(reference: Long01.apple, candidate: Long01.whisperWithoutPrompt) else {
            Issue.record("the text without «Alla fine voglio misurare quanto migliora» must be refused")
            return
        }
        #expect(without.missing == 6)
        #expect(without.unmatched == 6)
        #expect(without.written == 0)
        guard case let .refused(with) = TranscriptGapGuard.judge(reference: Long01.apple, candidate: Long01.whisperWithPrompt) else {
            Issue.record("the text without 25 words must be refused")
            return
        }
        #expect(with.missing == 25)
        #expect(TranscriptGapGuard.judge(reference: Long01.apple, candidate: Long01.whisperInPieces) == .accepted)
        #expect(TranscriptGapGuard.judge(reference: Long01.reference, candidate: Long01.whisperInPieces) == .accepted)
    }

    @Test("the cover rule scales with the run the caller asks for")
    func coverNet() {
        #expect(TranscriptGapGuard.coverNet(minimumRun: 5) == 3)
        #expect(TranscriptGapGuard.coverNet(minimumRun: 4) == 2)
        #expect(TranscriptGapGuard.coverNet(minimumRun: 1) == 1)
        // Four unmatched, two written (net 2): under the run of five, accepted.
        #expect(TranscriptGapGuard.findGap(reference: "uno due tre quattro cinque sei", candidate: "uno xx yy sei", minimumRun: 5) == nil)
        // Five unmatched, two written (net 3, the cover net): refused.
        let covered = TranscriptGapGuard.findGap(reference: "uno due tre quattro cinque sei sette", candidate: "uno xx yy sette", minimumRun: 5)
        #expect(covered == TranscriptGapGuard.Gap(missing: 3, at: 1, written: 2, unmatched: 5))
    }
}

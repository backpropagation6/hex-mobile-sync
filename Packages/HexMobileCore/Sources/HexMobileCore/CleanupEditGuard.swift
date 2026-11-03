import Foundation

/// What the text cleanup may take out of a dictation, and nothing else.
///
/// The model that cleans a dictation is told to add punctuation and capitals,
/// to drop hesitations and repetitions and to apply an explicit
/// self-correction. It also drops words it finds redundant («bene o male»),
/// the «di» before an infinitive, and rewrites «ed è» as «e è», and each of
/// these passes the bag-of-words check of ``CleanupGuard`` (phone, 2 Nov 2026:
/// inserted text at 2.7 % of wrong words against 2.5 % for the text it was
/// made from). Here the dictation and the cleaned text are aligned word by
/// word (the same alignment as ``TranscriptGapGuard``), and every difference
/// must be one of:
/// - case, punctuation or accents (they are not words after the folding below);
/// - a number written another way («3» and «tre», «2026» and «duemilaventisei»):
///   before the alignment ``ItalianNumber`` turns every number, in both texts,
///   into the same word;
/// - a hesitation that was removed (`ehm`, `mmm`, `uhm`, `eh`, `ah`…);
/// - the copy of a word, or of a phrase, that sits next to the kept one
///   («mi mi serve», «il mio il mio»);
/// - the phrase retracted right before a correction marker of the dictation,
///   and the marker itself (`no anzi`, `anzi`, `scusa`, `intendevo`,
///   `volevo dire`): at most ``defaultMaximumRetractedWords`` words before it.
///
/// A word that was replaced, added, moved or taken out for any other reason is
/// a violation, and the raw text stays. The price is a cleanup lost because
/// of one word the model judged better; the raw text keeps what the recognizer
/// wrote.
public enum CleanupEditGuard {
    /// How many words before a correction marker the retracted phrase may have.
    /// A choice made in place of the author (nothing on the phone measures it): a
    /// spoken retraction is a few words, and a longer cut right before an
    /// «anzi» is more likely a loss than a retraction.
    public static let defaultMaximumRetractedWords = 8

    /// What the cleaned text did that the rules do not allow.
    public struct Violation: Sendable, Equatable {
        /// Index, in the words of the dictation, of the first word that was
        /// removed or replaced without a rule to allow it (for an addition, of
        /// the word it was added in front of).
        public var at: Int
        /// Dictated words removed or replaced that no rule allows.
        public var removed: Int
        /// Words of the cleaned text with no counterpart in the dictation.
        public var added: Int
    }

    /// The first violation of the cleaned `output` against the dictated
    /// `input`, or `nil` when every difference is allowed.
    ///
    /// Two alignments are tried, one that keeps the first copy of a repeated
    /// stretch and one that keeps the last («ci vediamo domani alle tre no
    /// anzi domani alle quattro»: which «domani alle» was kept does not change
    /// what was retracted); the output is allowed if either one is.
    public static func violation(
        input: String,
        output: String,
        maximumRetractedWords: Int = defaultMaximumRetractedWords
    ) -> Violation? {
        let ref = words(input)
        let cand = words(output)
        guard (ref.count + 1) * (cand.count + 1) <= TranscriptGapGuard.maximumCells else {
            // Too long to align: not judged as allowed (a cleanup is at most 3,000 characters).
            return Violation(at: 0, removed: ref.count, added: cand.count)
        }
        let blocks = markerBlocks(in: ref)
        let forward = TranscriptGapGuard.matchedPairs(ref, cand)
        guard let first = evaluate(ref, cand, pairs: forward, blocks: blocks, maximumRetractedWords: maximumRetractedWords) else {
            return nil
        }
        let backward = TranscriptGapGuard.matchedPairs(Array(ref.reversed()), Array(cand.reversed()))
            .map { (ref.count - 1 - $0.0, cand.count - 1 - $0.1) }
            .reversed()
        guard let second = evaluate(ref, cand, pairs: Array(backward), blocks: blocks, maximumRetractedWords: maximumRetractedWords) else {
            return nil
        }
        return second.removed + second.added < first.removed + first.added ? second : first
    }

    /// The words of `text` as compared: no case, no accents, no punctuation
    /// (an apostrophe separates, `l'ufficio` is two words in both texts) and
    /// every number as digits.
    static func words(_ text: String) -> [String] {
        ItalianNumber.normalize(
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
                .map(String.init)
        )
    }

    // MARK: - Rules

    /// Hesitations, as folded words.
    static let hesitations: Set<String> = [
        "ehm", "ehmm", "ehhm", "eh", "ehh", "eeh", "mmm", "mm", "mhm", "hmm", "hm",
        "uhm", "uhmm", "uh", "um", "umm", "ah", "ahm", "ahh", "aah",
    ]

    /// Correction markers, as folded words. «no anzi» is one marker, and «anzi»
    /// alone is another.
    static let markers: [[String]] = [["no", "anzi"], ["anzi"], ["scusa"], ["intendevo"], ["volevo", "dire"]]

    /// The stretches of the dictation that are markers; markers that overlap or
    /// touch («scusa intendevo», «no anzi») are one block.
    static func markerBlocks(in ref: [String]) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        for index in ref.indices {
            for marker in markers where index + marker.count <= ref.count && Array(ref[index..<(index + marker.count)]) == marker {
                spans.append(index..<(index + marker.count))
            }
        }
        var merged: [Range<Int>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, span.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// Walks the alignment gap by gap (the dictated words not kept, and the
    /// words of the output with no counterpart, between two matched words).
    private static func evaluate(
        _ ref: [String],
        _ cand: [String],
        pairs: [(Int, Int)],
        blocks: [Range<Int>],
        maximumRetractedWords: Int
    ) -> Violation? {
        var kept = [Bool](repeating: false, count: ref.count)
        for (index, _) in pairs { kept[index] = true }

        var at: Int?
        var removed = 0
        var added = 0
        var previousRef = -1
        var previousCand = -1
        for (refIndex, candIndex) in pairs + [(ref.count, cand.count)] {
            let start = previousRef + 1
            let end = refIndex
            let addedWords = Array(cand[(previousCand + 1)..<candIndex])
            if end > start || !addedWords.isEmpty {
                let bad = badWords(
                    ref: ref, kept: kept, start: start, end: end, added: addedWords,
                    blocks: blocks, maximumRetractedWords: maximumRetractedWords
                )
                if bad.removed > 0 || bad.added > 0 {
                    if at == nil { at = bad.first ?? start }
                    removed += bad.removed
                    added += bad.added
                }
            }
            previousRef = refIndex
            previousCand = candIndex
        }
        return at.map { Violation(at: $0, removed: removed, added: added) }
    }

    /// The words of one gap that no rule allows. `start..<end` are the dictated
    /// words not kept (consecutive, with a kept word or an edge on each side).
    private static func badWords(
        ref: [String],
        kept: [Bool],
        start: Int,
        end: Int,
        added: [String],
        blocks: [Range<Int>],
        maximumRetractedWords: Int
    ) -> (removed: Int, added: Int, first: Int?) {
        // What is left once hesitations and the retracted phrase (with its marker) are set aside.
        let remaining = (start..<end).filter { index in
            !hesitations.contains(ref[index])
                && !blocks.contains { block in
                    index >= block.lowerBound - maximumRetractedWords
                        && index < block.upperBound
                        && (index >= block.lowerBound || end >= block.lowerBound)
                }
        }

        // Something was written where words were (or where nothing was): a word
        // replaced or added.
        if !added.isEmpty {
            return (remaining.count, added.count, remaining.first ?? start)
        }

        // Words taken out: whatever is left must be the copy of a word, or of a
        // phrase, that was kept next to it.
        if remaining.isEmpty { return (0, 0, nil) }
        let words = remaining.map { ref[$0] }
        if start > 0, words.allSatisfy({ $0 == ref[start - 1] }) { return (0, 0, nil) }
        if end < ref.count, words.allSatisfy({ $0 == ref[end] }) { return (0, 0, nil) }
        let count = words.count
        if start >= count, (start - count..<start).allSatisfy({ kept[$0] }), Array(ref[(start - count)..<start]) == words {
            return (0, 0, nil)
        }
        if end + count <= ref.count, (end..<(end + count)).allSatisfy({ kept[$0] }), Array(ref[end..<(end + count)]) == words {
            return (0, 0, nil)
        }
        return (remaining.count, 0, remaining.first)
    }
}

// MARK: - Numbers

/// Italian cardinal numbers as folded words, to tell that «tre» and «3», or
/// «duemilaventisei» and «2026», are the same number.
enum ItalianNumber {
    private enum Atom {
        case unit(Int)
        case tens(Int)
        case hundred
        case thousandSingular
        case thousands
        case million
        case billion
    }

    /// What may follow an atom that is a stem («vent» of «ventuno», «cent» of «centottanta»).
    private struct Entry {
        var text: String
        var atom: Atom
        var before: [String] = []
    }

    private static let entries: [Entry] = {
        var list: [Entry] = []
        let units = [
            "zero": 0, "uno": 1, "un": 1, "una": 1, "due": 2, "tre": 3, "quattro": 4, "cinque": 5, "sei": 6,
            "sette": 7, "otto": 8, "nove": 9, "dieci": 10, "undici": 11, "dodici": 12, "tredici": 13,
            "quattordici": 14, "quindici": 15, "sedici": 16, "diciassette": 17, "diciotto": 18, "diciannove": 19,
        ]
        for (text, value) in units { list.append(Entry(text: text, atom: .unit(value))) }
        let tens = [
            "venti": 20, "trenta": 30, "quaranta": 40, "cinquanta": 50,
            "sessanta": 60, "settanta": 70, "ottanta": 80, "novanta": 90,
        ]
        for (text, value) in tens {
            list.append(Entry(text: text, atom: .tens(value)))
            // «ventuno», «ventotto»: the last vowel goes before «uno» and «otto».
            list.append(Entry(text: String(text.dropLast()), atom: .tens(value), before: ["uno", "un", "otto"]))
        }
        list.append(Entry(text: "cento", atom: .hundred))
        list.append(Entry(text: "cent", atom: .hundred, before: ["otto"]))
        list.append(Entry(text: "mille", atom: .thousandSingular))
        list.append(Entry(text: "mila", atom: .thousands))
        for text in ["milione", "milioni"] { list.append(Entry(text: text, atom: .million)) }
        for text in ["miliardo", "miliardi"] { list.append(Entry(text: text, atom: .billion)) }
        // Longest first, so «tredici» is not «tre» + «dici».
        return list.sorted { $0.text.count > $1.text.count }
    }()

    /// `tokens` with every run that spells a number replaced by its digits
    /// («alle», «venti», «cinque» becomes «alle», «25»; «2», «026» becomes
    /// «2026»). The longest well-formed run wins, so «tre due» stays two
    /// numbers. A lone «un», «uno» or «una» is an article as often as a number
    /// and stays as it is.
    static func normalize(_ tokens: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < tokens.count {
            guard isPart(tokens[index]) else {
                result.append(tokens[index])
                index += 1
                continue
            }
            var end = index + 1
            while end < tokens.count, end - index < maximumRun, isPart(tokens[end]) || tokens[end] == "e" { end += 1 }
            var length = end - index
            var number: Int?
            while length > 0 {
                let last = tokens[index + length - 1]
                if last != "e", let value = value(of: Array(tokens[index..<(index + length)])) {
                    number = value
                    break
                }
                length -= 1
            }
            if let number, !(length == 1 && articles.contains(tokens[index])) {
                result.append(String(number))
            } else {
                result.append(contentsOf: tokens[index..<(index + max(length, 1))])
            }
            index += max(length, 1)
        }
        return result
    }

    /// A number is at most this many words («duemila», «trecento», «venti», «sei»).
    private static let maximumRun = 8

    private static let articles: Set<String> = ["un", "uno", "una"]

    /// Whether `token` is, alone, a number: digits or a number word.
    private static func isPart(_ token: String) -> Bool {
        if token.allSatisfy(\.isASCIIDigit) { return true }
        return token.count >= 2 && parse(Substring(token)) != nil
    }

    /// The number the folded `tokens` spell: digits («2026», «2», «026» for
    /// 2.026) or words («venti», «sei», «mille», «e», «due»), or `nil`.
    static func value(of tokens: [String]) -> Int? {
        guard !tokens.isEmpty else { return nil }
        if tokens.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }) {
            if tokens.count == 1 { return tokens[0].count <= 15 ? Int(tokens[0]) : nil }
            guard tokens[0].count <= 3, tokens.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            return Int(tokens.joined())
        }
        let spelled = tokens.count > 1 ? tokens.filter { $0 != "e" } : tokens
        guard !spelled.isEmpty, let atoms = parse(Substring(spelled.joined())) else { return nil }
        // A well-formed number only: units and tens do not pile up («tre due» is not 5).
        var total = 0
        var group = 0
        for atom in atoms {
            let low = group % 100
            switch atom {
            case let .unit(value):
                if value == 0, atoms.count > 1 { return nil }
                guard low == 0 || (value < 10 && low >= 20 && low % 10 == 0) else { return nil }
                group += value
            case let .tens(value):
                guard low == 0 else { return nil }
                group += value
            case .hundred:
                guard group < 10 else { return nil }
                group = max(group, 1) * 100
            case .thousandSingular:
                guard group == 0 else { return nil }
                total += 1_000
            case .thousands:
                guard group > 0, group < 1_000 else { return nil }
                total += group * 1_000
                group = 0
            case .million:
                guard group < 1_000 else { return nil }
                total += max(group, 1) * 1_000_000
                group = 0
            case .billion:
                guard group < 1_000 else { return nil }
                total += max(group, 1) * 1_000_000_000
                group = 0
            }
        }
        return total + group
    }

    /// The atoms `text` is made of, longest match first with backtracking.
    private static func parse(_ text: Substring) -> [Atom]? {
        if text.isEmpty { return [] }
        for entry in entries where text.hasPrefix(entry.text) {
            let rest = text.dropFirst(entry.text.count)
            if !entry.before.isEmpty, !entry.before.contains(where: { rest.hasPrefix($0) }) { continue }
            if let tail = parse(rest) { return [entry.atom] + tail }
        }
        return nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

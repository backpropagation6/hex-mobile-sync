import Foundation

/// Finds text that a second transcript lost: a run of consecutive words of
/// the first one that the second one has no word for.
///
/// The length of the texts does not see it. On 2 Nov 2026 Whisper's text of a
/// 42 s dictation had 728 characters against Apple's 760 (96 %), with a whole
/// sentence missing; the rule "at least half of the words" keeps such a text.
/// Here the two are aligned word by word (the longest common subsequence of
/// the normalized words, the same normalization as ``WordErrorRate``), and what
/// is left between two matched words is compared: words of the reference with
/// no counterpart on the other side (`unmatched`) against words of the
/// candidate with no counterpart (`written`). A word replaced by another (a
/// name spelled differently, a number written out) is a substitution: it adds
/// to both, and costs nothing.
///
/// A gap is refused when
/// - the reference has at least `minimumRun` more words in it than the
///   candidate (`missing = unmatched - written`), or
/// - the reference has at least `minimumRun` unmatched words and the
///   candidate wrote at least ``coverNet(minimumRun:)`` fewer: a loss that the
///   candidate partly covers with words of its own, which is how a Whisper
///   hallucination (a subtitle credit, a thanks) fills the silence at the end
///   of a piece. The net rule alone lets nine lost words behind five
///   invented ones pass (net 4); a legitimate rewording writes about as many
///   words as it replaces and does not trip this.
///
/// Gaps separated by a single matched word of two characters or fewer count as
/// one: the aligner takes any `il`, `di`, `e` that occurs inside a lost
/// stretch as an anchor and would split a loss of five words in two and
/// three. Two or more matched words in a row are a real anchor.
///
/// It is a guard against lost text, not a judge of accuracy. It is
/// conservative on purpose: if the reference itself holds a run of five words
/// that the candidate lacks because the reference is wrong (a repeated
/// phrase, a hallucination), a correct candidate is refused and the
/// reference text stays.
public enum TranscriptGapGuard {
    /// Consecutive missing words that make a candidate unusable. Five covers
    /// both losses seen on 2 Nov 2026 (6 and 25 words) and is more than
    /// any run of fillers or one-word spelling variants seen in the bench
    /// (the longest deletion run between Apple's and Whisper's complete
    /// texts of 13 clips was 1).
    public static let defaultMinimumRun = 5

    /// How many words fewer the candidate must have written, in a gap with at
    /// least `minimumRun` unmatched reference words, to refuse it: half the run,
    /// rounded up (3 for five). Not measured on a phone: chosen so that the
    /// review's case (nine lost, five invented) is refused and a rewording of
    /// five words by five (net 0) is not.
    public static func coverNet(minimumRun: Int) -> Int {
        max(1, (minimumRun + 1) / 2)
    }

    /// A matched word of this many characters or fewer, alone between two gaps,
    /// does not keep them apart (`il`, `di`, `e`, `a`, `la`).
    static let shortAnchorCharacters = 2

    /// The alignment is a table of `reference × candidate` words; above this
    /// many cells (about 1000 words each way, 4 MB) the guard is not run. Whisper
    /// only runs on dictations that fit a few seconds, far below it.
    static let maximumCells = 1_000_000

    public struct Gap: Sendable, Equatable {
        /// Words of the reference the candidate lacks: `unmatched - written`.
        public var missing: Int
        /// Index, in the reference's words, of the first unmatched one.
        public var at: Int
        /// Reference words with no counterpart in the gap (the gross count).
        public var unmatched: Int
        /// Candidate words with no counterpart in the gap.
        public var written: Int

        public init(missing: Int, at: Int, written: Int = 0, unmatched: Int? = nil) {
            self.missing = missing
            self.at = at
            self.written = written
            self.unmatched = unmatched ?? (missing + written)
        }
    }

    /// What the guard says about a candidate.
    public enum Verdict: Sendable, Equatable {
        /// No gap that reaches the run.
        case accepted
        /// A gap that does: the worst one.
        case refused(Gap)
        /// The texts are too long to align (`cells` of the table): the guard
        /// did not run and the candidate is not judged. Callers log it.
        case notJudged(cells: Int)
    }

    /// The gaps of `candidate` against `reference`, merged across single short
    /// anchors, in text order; `nil` when the texts are too long to align.
    static func gaps(reference ref: [String], candidate cand: [String]) -> [Gap]? {
        guard (ref.count + 1) * (cand.count + 1) <= maximumCells else { return nil }
        if cand.isEmpty { return ref.isEmpty ? [] : [Gap(missing: ref.count, at: 0)] }

        var merged: [Gap] = []
        var previousRef = -1
        var previousCand = -1
        // Matched words since the last gap, and whether the last one is short.
        var anchorsSinceGap = 0
        var lastAnchorIsShort = false
        for (refIndex, candIndex) in matchedPairs(ref, cand) + [(ref.count, cand.count)] {
            let unmatched = refIndex - previousRef - 1
            let written = candIndex - previousCand - 1
            if unmatched > 0 || written > 0 {
                if var last = merged.last, anchorsSinceGap == 1, lastAnchorIsShort {
                    last.unmatched += unmatched
                    last.written += written
                    last.missing = last.unmatched - last.written
                    merged[merged.count - 1] = last
                } else {
                    merged.append(Gap(missing: unmatched - written, at: previousRef + 1, written: written, unmatched: unmatched))
                }
                anchorsSinceGap = 0
            }
            if refIndex < ref.count {
                anchorsSinceGap += 1
                lastAnchorIsShort = ref[refIndex].count <= shortAnchorCharacters
            }
            previousRef = refIndex
            previousCand = candIndex
        }
        return merged
    }

    /// The gap with the most words of the reference missing (`missing`), or
    /// `nil` when there is none (or the texts are too long to align).
    public static func largestGap(reference: String, candidate: String) -> Gap? {
        let ref = WordErrorRate.words(in: reference)
        guard !ref.isEmpty,
              let gaps = gaps(reference: ref, candidate: WordErrorRate.words(in: candidate))
        else { return nil }
        var best: Gap?
        for gap in gaps where gap.missing > 0 && gap.missing > (best?.missing ?? 0) {
            best = gap
        }
        return best
    }

    /// Whether `gap` is enough to refuse a candidate.
    static func refuses(_ gap: Gap, minimumRun: Int) -> Bool {
        gap.missing >= minimumRun
            || (gap.unmatched >= minimumRun && gap.missing >= coverNet(minimumRun: minimumRun))
    }

    /// Judges `candidate` against `reference`: the worst gap that
    /// ``refuses(_:minimumRun:)``, if any (most missing words, then most
    /// unmatched, then the first).
    public static func judge(
        reference: String,
        candidate: String,
        minimumRun: Int = defaultMinimumRun
    ) -> Verdict {
        let ref = WordErrorRate.words(in: reference)
        let cand = WordErrorRate.words(in: candidate)
        guard !ref.isEmpty else { return .accepted }
        guard let gaps = gaps(reference: ref, candidate: cand) else {
            return .notJudged(cells: (ref.count + 1) * (cand.count + 1))
        }
        var worst: Gap?
        for gap in gaps where refuses(gap, minimumRun: minimumRun) {
            if let current = worst, (gap.missing, gap.unmatched) <= (current.missing, current.unmatched) { continue }
            worst = gap
        }
        return worst.map(Verdict.refused) ?? .accepted
    }

    /// The gap that makes ``judge(reference:candidate:minimumRun:)`` refuse, or
    /// `nil` (accepted, or too long to judge).
    public static func findGap(
        reference: String,
        candidate: String,
        minimumRun: Int = defaultMinimumRun
    ) -> Gap? {
        if case let .refused(gap) = judge(reference: reference, candidate: candidate, minimumRun: minimumRun) {
            return gap
        }
        return nil
    }

    /// The matched word positions `(reference index, candidate index)` of one
    /// longest common subsequence, in order.
    static func matchedPairs(_ ref: [String], _ cand: [String]) -> [(Int, Int)] {
        let rows = ref.count + 1
        let columns = cand.count + 1
        // length[i * columns + j]: the common subsequence of ref[i...] and cand[j...].
        var length = [Int32](repeating: 0, count: rows * columns)
        for i in stride(from: ref.count - 1, through: 0, by: -1) {
            for j in stride(from: cand.count - 1, through: 0, by: -1) {
                if ref[i] == cand[j] {
                    length[i * columns + j] = length[(i + 1) * columns + j + 1] + 1
                } else {
                    length[i * columns + j] = max(length[(i + 1) * columns + j], length[i * columns + j + 1])
                }
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < ref.count, j < cand.count {
            if ref[i] == cand[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if length[(i + 1) * columns + j] >= length[i * columns + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}

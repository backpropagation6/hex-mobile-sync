import Foundation

/// Word error rate, for comparing recognizer variants on the same clips.
///
/// "Normalized": case, punctuation, apostrophes and hyphens do not count (the
/// final text is judged on words; formatting is judged by reading it). Accents
/// do: `perche` for `perché` is a wrong word in written Italian.
public enum WordErrorRate {
    public struct Score: Sendable, Equatable {
        public var substitutions: Int
        public var deletions: Int
        public var insertions: Int
        public var referenceWords: Int

        public init(substitutions: Int, deletions: Int, insertions: Int, referenceWords: Int) {
            self.substitutions = substitutions
            self.deletions = deletions
            self.insertions = insertions
            self.referenceWords = referenceWords
        }

        public var errors: Int { substitutions + deletions + insertions }

        /// Errors over reference words. Nil for an empty reference.
        public var rate: Double? {
            referenceWords > 0 ? Double(errors) / Double(referenceWords) : nil
        }
    }

    /// The words of `text`: lowercased, split on anything that is not a letter
    /// or digit.
    public static func words(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    /// Levenshtein alignment over words, counting each kind of error.
    public static func score(reference: String, hypothesis: String) -> Score {
        let ref = words(in: reference)
        let hyp = words(in: hypothesis)
        if ref.isEmpty { return Score(substitutions: 0, deletions: 0, insertions: hyp.count, referenceWords: 0) }
        if hyp.isEmpty { return Score(substitutions: 0, deletions: ref.count, insertions: 0, referenceWords: ref.count) }

        // cost[i][j]: edit distance of ref[..<i] to hyp[..<j], with the counts
        // of the cheapest path (ties prefer substitutions, then deletions).
        struct Cell { var cost: Int; var sub: Int; var del: Int; var ins: Int }
        var previous = (0...hyp.count).map { Cell(cost: $0, sub: 0, del: 0, ins: $0) }
        for i in 1...ref.count {
            var current = [Cell(cost: i, sub: 0, del: i, ins: 0)]
            for j in 1...hyp.count {
                let diagonal = previous[j - 1]
                let match = ref[i - 1] == hyp[j - 1]
                var best = Cell(
                    cost: diagonal.cost + (match ? 0 : 1),
                    sub: diagonal.sub + (match ? 0 : 1),
                    del: diagonal.del,
                    ins: diagonal.ins
                )
                let up = previous[j]
                if up.cost + 1 < best.cost {
                    best = Cell(cost: up.cost + 1, sub: up.sub, del: up.del + 1, ins: up.ins)
                }
                let left = current[j - 1]
                if left.cost + 1 < best.cost {
                    best = Cell(cost: left.cost + 1, sub: left.sub, del: left.del, ins: left.ins + 1)
                }
                current.append(best)
            }
            previous = current
        }
        let end = previous[hyp.count]
        return Score(substitutions: end.sub, deletions: end.del, insertions: end.ins, referenceWords: ref.count)
    }

    /// The corpus rate: total errors over total reference words.
    public static func corpusRate(_ scores: [Score]) -> Double? {
        let words = scores.reduce(0) { $0 + $1.referenceWords }
        guard words > 0 else { return nil }
        return Double(scores.reduce(0) { $0 + $1.errors }) / Double(words)
    }
}

/// The right text of each clip, for scoring: a JSON object `{"clip-id": "text"}`
/// or lines `clip-id<TAB>text`. A trailing `.caf` on an id is ignored; blank
/// lines and lines starting with `#` are skipped.
public enum ReferenceFile {
    public static func parse(_ data: Data) throws -> [String: String] {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            let object = try JSONDecoder().decode([String: String].self, from: Data(trimmed.utf8))
            return Dictionary(object.map { (clipID($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        var result: [String: String] = [:]
        for line in trimmed.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("#"), let tab = line.firstIndex(of: "\t") else { continue }
            let id = clipID(String(line[..<tab]))
            let text = line[line.index(after: tab)...].trimmingCharacters(in: .whitespaces)
            if !id.isEmpty, !text.isEmpty, result[id] == nil { result[id] = text }
        }
        return result
    }

    private static func clipID(_ raw: String) -> String {
        var id = raw.trimmingCharacters(in: .whitespaces)
        if id.hasSuffix(".caf") { id.removeLast(4) }
        return id
    }
}

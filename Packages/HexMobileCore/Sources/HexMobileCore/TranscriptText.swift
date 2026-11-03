import Foundation

extension String {
    /// Joins transcript segments with exactly one space where needed.
    ///
    /// The recognizer returns each finalized segment as a sentence of its own,
    /// so a segment after the first starts with a capital even when the
    /// sentence goes on («Okay, quindi Funziona tutto.», 1 Nov 2026). The join
    /// leaves the capital alone: lowercasing it in code would break proper
    /// names, and the text cleanup (the on-device language model) is the step
    /// that fixes it.
    public func appendingSegment(_ segment: String) -> String {
        let trimmedSegment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSegment.isEmpty else { return self }
        guard !isEmpty else { return trimmedSegment }
        if let last = last, last.isWhitespace { return self + trimmedSegment }
        if let first = trimmedSegment.first, first.isPunctuation, first != "(", first != "\"" {
            return self + trimmedSegment
        }
        return self + " " + trimmedSegment
    }
}

/// Builds the running transcript from recognizer results: finalized segments
/// are appended in order, the volatile tail is replaced by every new volatile
/// result and dropped when a final result arrives.
public struct TranscriptAssembler: Sendable, Equatable {
    /// The finalized segments joined so far.
    public private(set) var finalized = ""
    /// The tail the recognizer may still revise.
    public private(set) var volatile = ""

    public init() {}

    /// Feeds one result.
    public mutating func receive(text: String, isFinal: Bool) {
        if isFinal {
            finalized = finalized.appendingSegment(text)
            volatile = ""
        } else {
            volatile = text
        }
    }

    /// The whole transcript: some locales leave the last words volatile at the
    /// end of the input, so the tail is part of it.
    public var text: String { finalized.appendingSegment(volatile) }

    /// Whether nothing was received yet.
    public var isEmpty: Bool { finalized.isEmpty && volatile.isEmpty }

    /// Forgets everything.
    public mutating func reset() {
        finalized = ""
        volatile = ""
    }
}

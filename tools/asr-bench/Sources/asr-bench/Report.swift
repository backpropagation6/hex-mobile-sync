import Foundation
import HexMobileCore

enum Report {
    static func printClip(_ clip: ClipReport) {
        print("\n== \(clip.id)  \(String(format: "%.1f", clip.audioSeconds)) s")
        if let reference = clip.reference { print("   reference        | \(reference)") }
        for measurement in clip.measurements {
            let name = measurement.variant.padding(toLength: 16, withPad: " ", startingAt: 0)
            if let error = measurement.error {
                print("   \(name) | ERROR \(error)")
                continue
            }
            var line = "   \(name) |"
            if let seconds = measurement.seconds { line += " \(String(format: "%5.2f", seconds)) s" }
            if let wer = measurement.wer, let rate = wer.score.rate { line += " wer \(String(format: "%5.1f", rate * 100))%" }
            print("\(line) | \(measurement.text ?? "")")
            if let note = measurement.note { print("   \(String(repeating: " ", count: 16)) | (\(note))") }
        }
    }

    /// One row per variant: corpus WER over the clips that have a reference,
    /// and the latency.
    static func printSummary(_ clips: [ClipReport]) {
        var names: [String] = []
        for clip in clips { for m in clip.measurements where !names.contains(m.variant) { names.append(m.variant) } }
        print("\n== summary  clips=\(clips.count)  with reference=\(clips.filter { $0.reference != nil }.count)")
        print("variant            clips  err   WER     S    D    I  words   mean s   max s")
        for name in names {
            let all = clips.compactMap { clip in clip.measurements.first { $0.variant == name }.map { (clip, $0) } }
            let okay = all.filter { $0.1.error == nil && $0.1.text != nil }
            let errors = all.count - okay.count
            let scores = okay.compactMap { $0.1.wer?.score }
            let rate = WordErrorRate.corpusRate(scores).map { String(format: "%5.1f%%", $0 * 100) } ?? "   n/a"
            let s = scores.reduce(0) { $0 + $1.substitutions }
            let d = scores.reduce(0) { $0 + $1.deletions }
            let i = scores.reduce(0) { $0 + $1.insertions }
            let words = scores.reduce(0) { $0 + $1.referenceWords }
            let times = okay.compactMap { $0.1.seconds }
            let mean = times.isEmpty ? "     -" : String(format: "%6.2f", times.reduce(0, +) / Double(times.count))
            let maximum = times.max().map { String(format: "%6.2f", $0) } ?? "     -"
            let label = name.padding(toLength: 16, withPad: " ", startingAt: 0)
            print("\(label)  \(pad(okay.count, 5))  \(pad(errors, 3))  \(rate)  \(pad(s, 4)) \(pad(d, 4)) \(pad(i, 4))  \(pad(words, 5))  \(mean)  \(maximum)")
        }
    }

    static func writeJSON(_ clips: [ClipReport], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(clips).write(to: url, options: .atomic)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        String(value).padding(toLength: max(width, String(value).count), withPad: " ", startingAt: 0)
    }
}

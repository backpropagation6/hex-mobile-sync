import Foundation

/// Why the recognizers get no vocabulary hint, for the screens that say so.
///
/// On 2 Nov 2026 the phone logged `whisper prompt terms=0/0`: until the user
/// picks the Hex Mobile folder (or adds a term on the iPhone) the list of
/// terms that biases Apple's recognizer and Whisper's prompt is empty, and
/// nothing on screen said so.
public enum VocabularyNotice: Equatable, Sendable {
    /// No terms and no sync folder: picking the folder is the way out.
    case noFolder
    /// A folder is picked but no term came out of it (not synced yet, or Hex
    /// has none) and none was added here.
    case noTerms

    /// The notice for the current state, or `nil` when there are terms.
    ///
    /// - Parameters:
    ///   - termCount: terms that reach the recognizers (``ContextualVocabulary``).
    ///   - folderPicked: a sync folder is set.
    public static func make(termCount: Int, folderPicked: Bool) -> VocabularyNotice? {
        guard termCount <= 0 else { return nil }
        return folderPicked ? .noTerms : .noFolder
    }
}

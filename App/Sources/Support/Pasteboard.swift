import HexMobileCore
import UIKit

/// Writes finished dictations to the general pasteboard.
///
/// Privacy: copies are local-only (no Universal Clipboard to the user's other
/// devices) unless the user allows Universal Clipboard in Settings. A copy
/// made only so the keyboard can insert the text (Copy to Clipboard off) is
/// always local-only and expires after ``DictationPayload/defaultMaxAge``.
@MainActor
enum DictationPasteboard {
    /// Puts the text on the pasteboard together with the JSON payload the
    /// keyboard uses to insert it once.
    /// - Parameters:
    ///   - localOnly: keep the copy off Universal Clipboard.
    ///   - expiresAfter: remove the copy after this many seconds; `nil` keeps it.
    static func write(_ record: DictationRecord, localOnly: Bool, expiresAfter: TimeInterval? = nil) {
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: localOnly]
        if let expiresAfter {
            options[.expirationDate] = Date().addingTimeInterval(expiresAfter)
        }
        let payload = DictationPayload(record: record)
        let item = (try? payload.pasteboardItem()) ?? [HexMobileIPC.plainTextPasteboardType: record.text]
        UIPasteboard.general.setItems([item], options: options)
    }

    /// Hands a keyboard-triggered dictation to the keyboard when the user
    /// turned Copy to Clipboard off: local-only, gone after two minutes.
    static func handOffToKeyboard(_ record: DictationRecord) {
        write(record, localOnly: true, expiresAfter: DictationPayload.defaultMaxAge)
    }
}

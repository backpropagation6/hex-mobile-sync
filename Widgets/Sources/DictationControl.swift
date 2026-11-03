import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen / Action Button control that toggles dictation.
///
/// It is a button, not a stateful `ControlWidgetToggle`: without an App Group
/// the extension cannot read whether the app is recording, so it could not
/// show a reliable on/off state. The Live Activity shows the state instead.
struct DictationControl: ControlWidget {
    static let kind = "io.github.hexmobile.control.dictation"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleDictationIntent()) {
                Label("Hex Dictation", image: "hex.mark")
            }
        }
        .displayName("Hex Dictation")
        .description("Start dictation, or stop and copy the text.")
    }
}

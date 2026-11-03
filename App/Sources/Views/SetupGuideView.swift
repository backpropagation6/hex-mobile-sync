import SwiftUI

/// Step-by-step setup instructions.
struct SetupGuideView: View {
    enum Guide {
        case keyboard
        case actionButton
        case controlCenter
        case sync
    }

    let guide: Guide

    var body: some View {
        List {
            Group {
                Section {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(verbatim: "\(index + 1)")
                                .font(.headline.monospacedDigit())
                                .frame(width: 28, height: 28)
                                .overlay(Hexagon().stroke(HexPalette.foreground, lineWidth: 1.5))
                                .foregroundStyle(HexPalette.foreground)
                                .accessibilityHidden(true)
                            Text(step)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                } footer: {
                    if let note {
                        Text(note)
                    }
                }
            }
            .listRowBackground(HexPalette.card)
        }
        .hexListBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var title: LocalizedStringKey {
        switch guide {
        case .keyboard: "Keyboard"
        case .actionButton: "Action Button"
        case .controlCenter: "Control Center"
        case .sync: "Sync with Hex on Mac"
        }
    }

    private var steps: [LocalizedStringKey] {
        switch guide {
        case .keyboard:
            [
                "Open the Settings app, then General > Keyboard > Keyboards > Add New Keyboard, and choose Hex Mobile.",
                "Tap Hex Mobile in the list and turn on Allow Full Access. The keyboard needs it to read the dictation from the clipboard; it has no network access.",
                "In any app, switch to the Hex Mobile keyboard with the globe key and tap the microphone. Hex Mobile opens and starts dictating at once: go back to your app with the button at the top left, or by swiping right along the bottom edge.",
                "While it listens, tap ✓ (or the microphone) to stop: the text is inserted where the cursor is. ✕ cancels. While a flow session is running (Dictate tab or Settings), the microphone dictates without leaving the app.",
            ]
        case .actionButton:
            [
                "Open the Settings app and choose Action Button.",
                "Swipe to Controls, tap Choose a Control, and pick Hex Dictation. Alternatively pick Shortcut and choose Dictate with Hex Mobile.",
                "Press the Action Button to start dictation, and press it again to stop. The text is copied to the clipboard, and the microphone turns off as soon as the Hex Mobile keyboard has taken the text, after a minute at most, unless a flow session was already running.",
            ]
        case .controlCenter:
            [
                "Open Control Center and tap + in the top-left corner.",
                "Tap Add a Control and search for Hex Dictation.",
                "Tap the control to start dictation and again to stop. A Live Activity shows while recording.",
            ]
        case .sync:
            [
                "On your Mac, install the sync script from the mac/ folder of this project. It exports the Hex vocabulary and text rules to iCloud Drive > Hex Mobile.",
                "On iPhone, open Settings > Sync with Hex > Choose Sync Folder, and pick iCloud Drive > Hex Mobile.",
                "Terms you add in the Vocabulary tab are written to the same folder and added to Hex the next time the Mac script runs while Hex is open.",
            ]
        }
    }

    private var note: LocalizedStringKey? {
        switch guide {
        case .keyboard:
            "iOS does not always allow keyboards to open apps; if nothing happens, open Hex Mobile and start a flow session there, then come back."
        case .actionButton, .controlCenter:
            "iOS may ask to confirm the first time. The microphone indicator stays on while recording."
        case .sync:
            "No iCloud permission is needed: the app only accesses the folder you pick."
        }
    }
}

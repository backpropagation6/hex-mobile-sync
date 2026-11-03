#if DEBUG
import SwiftUI
import UIKit

/// `-HexMobileKeyboardProbe YES` (Debug builds only): a text field that takes
/// focus at launch and asks for the Hex Mobile keyboard, so the keyboard
/// extension runs on the simulator without anyone using the globe key. It
/// overrides the public `UIResponder.textInputMode`, which is how a field
/// picks a keyboard; the field shows the keyboard only if the simulator is
/// set to the software keyboard.
struct DebugKeyboardProbe: UIViewRepresentable {
    final class Field: UITextField {
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { ($0.value(forKey: "identifier") as? String)?.hasSuffix("Keyboard") == true } ?? super.textInputMode
        }
    }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.placeholder = "keyboard probe"
        field.borderStyle = .roundedRect
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let modes = UITextInputMode.activeInputModes.map { ($0.value(forKey: "identifier") as? String) ?? "?" }
            Diagnostics.record("keyboard probe modes=\(modes)")
            let focused = field.becomeFirstResponder()
            Diagnostics.record("keyboard probe focus=\(focused) mode=\((field.textInputMode?.value(forKey: "identifier") as? String) ?? "-")")
        }
        // `-HexMobileKeyboardProbeResign N`: the field gives the keyboard up
        // after N seconds, the orderly end of a keyboard session (a killed
        // host never sends it).
        let resign = UserDefaults.standard.integer(forKey: "HexMobileKeyboardProbeResign")
        if resign > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(resign)) {
                let resigned = field.resignFirstResponder()
                Diagnostics.record("keyboard probe resigned=\(resigned)")
            }
        }
        // `-HexMobileKeyboardProbeFlick N` (with `-HexMobileKeyboardProbeFlickMs M`,
        // default 40): after the first focus, the field gives the keyboard up
        // and asks for it again N times, M ms apart: iOS loads a keyboard
        // controller that it then drops before it ever shows (the phone log of
        // 2 Nov 2026: `keyboard load` with no `appear`).
        let flick = UserDefaults.standard.integer(forKey: "HexMobileKeyboardProbeFlick")
        if flick > 0 {
            let gap = max(0, UserDefaults.standard.object(forKey: "HexMobileKeyboardProbeFlickMs") as? Int ?? 40)
            for cycle in 0..<flick {
                // Each cycle: 1.5 s apart so that the previous controller is done.
                let start = 2.0 + Double(cycle) * 1.5
                DispatchQueue.main.asyncAfter(deadline: .now() + start) {
                    _ = field.resignFirstResponder()
                    _ = field.becomeFirstResponder()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + start + Double(gap) / 1000) {
                    let resigned = field.resignFirstResponder()
                    Diagnostics.record("keyboard probe flick=\(cycle) resigned=\(resigned)")
                }
            }
        }
        return field
    }

    func updateUIView(_ uiView: Field, context: Context) {}
}
#endif

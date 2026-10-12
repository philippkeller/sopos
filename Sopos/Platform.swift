import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The few things iPhone and Mac do differently; everything else is shared.
enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

extension View {
    /// Buttons used as list rows: macOS would otherwise draw each one as a push button.
    func rowButton() -> some View {
        #if os(macOS)
        buttonStyle(.plain)
        #else
        self
        #endif
    }
}

import SwiftUI
#if os(iOS)
import UIKit
typealias PlatformViewRepresentable = UIViewRepresentable
#else
import AppKit
typealias PlatformViewRepresentable = NSViewRepresentable
#endif

/// Pequeñas diferencias entre iPadOS y macOS, para que las vistas sean las mismas.
enum Clipboard {
    static var string: String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}

extension View {
    /// Campo para pegar URLs: sin mayúsculas automáticas ni autocorrección.
    func urlInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        #else
        self.autocorrectionDisabled()
        #endif
    }

    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// En macOS las hojas se ajustan al contenido y salen muy pequeñas: les damos un tamaño cómodo.
    func sheetSize(width: CGFloat = 480, height: CGFloat = 300) -> some View {
        #if os(macOS)
        self.frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #else
        self
        #endif
    }
}

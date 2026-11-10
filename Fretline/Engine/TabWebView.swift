import SwiftUI
import WebKit

/// Muestra el WKWebView de un `TabEngine` (el engine es dueño de la vista y sobrevive a re-renders).
struct TabWebView: UIViewRepresentable {
    let engine: TabEngine

    func makeUIView(context: Context) -> WKWebView { engine.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

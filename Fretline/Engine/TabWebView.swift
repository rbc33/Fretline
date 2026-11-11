import SwiftUI
import WebKit

/// Muestra el WKWebView de un `TabEngine` (el engine es dueño de la vista y sobrevive a re-renders).
struct TabWebView: PlatformViewRepresentable {
    let engine: TabEngine

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { engine.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    #else
    func makeNSView(context: Context) -> WKWebView { engine.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    #endif
}

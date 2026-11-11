import SwiftUI
import WebKit

struct YouTubePlayerView: PlatformViewRepresentable {
    let player: YouTubePlayer

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { player.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    #else
    func makeNSView(context: Context) -> WKWebView { player.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    #endif
}

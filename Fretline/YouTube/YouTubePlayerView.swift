import SwiftUI
import WebKit

struct YouTubePlayerView: UIViewRepresentable {
    let player: YouTubePlayer

    func makeUIView(context: Context) -> WKWebView { player.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

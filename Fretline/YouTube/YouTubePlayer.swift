import Foundation
import WebKit
import Observation

/// Reproductor de YouTube (IFrame Player API) en su propio WKWebView.
/// Va separado de la vista de la tab porque YouTube exige un origen https:
/// la página se carga con baseURL https://<bundle id>, que es lo que YouTube pide a las apps nativas.
@MainActor
@Observable
final class YouTubePlayer: NSObject, WKScriptMessageHandler {
    let webView: WKWebView

    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var durationMs: Double = 0
    private(set) var currentTimeMs: Double = 0
    private(set) var errorMessage: String?
    private(set) var videoId: String?
    private(set) var rate: Double = 1

    @ObservationIgnored var onTime: ((Double) -> Void)?
    @ObservationIgnored var onPlayingChanged: ((Bool) -> Void)?
    @ObservationIgnored var onDuration: ((Double) -> Void)?

    @ObservationIgnored private var apiReady = false
    /// Posición en la que debe empezar el vídeo cuando aún no está listo para hacer seek
    @ObservationIgnored private var pendingStartMs: Double = 0
    @ObservationIgnored private var lastTickDate = Date()

    /// Tiempo estimado ahora mismo (interpola desde el último tick); útil para el tap-along.
    var estimatedTimeMs: Double {
        guard isPlaying else { return currentTimeMs }
        return currentTimeMs + Date().timeIntervalSince(lastTickDate) * 1000 * rate
    }

    override init() {
        let config = WKWebViewConfiguration()
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        config.mediaTypesRequiringUserActionForPlayback = []
        let controller = WKUserContentController()
        config.userContentController = controller
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 270), configuration: config)
        super.init()
        controller.add(WeakScriptMessageHandler(self), name: "yt")
        webView.isInspectable = true
        #if os(iOS)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = false
        #endif
        let origin = "https://\((Bundle.main.bundleIdentifier ?? "com.rbc33.fretline").lowercased())"
        webView.loadHTMLString(Self.html, baseURL: URL(string: origin))
    }

    // MARK: - Comandos

    func load(videoId: String) {
        guard videoId != self.videoId else { return }
        self.videoId = videoId
        isReady = false
        errorMessage = nil
        durationMs = 0
        currentTimeMs = pendingStartMs
        cue()
    }

    /// Destruye el reproductor (al pasar al sintetizador) para que su sesión de medios
    /// no interrumpa el audio de la partitura. `load` lo vuelve a crear.
    func unload() {
        js("unload()")
        videoId = nil
        isReady = false
        isPlaying = false
        pendingStartMs = 0
    }

    private func cue() {
        guard apiReady, let videoId else { return }
        js("cue(\(Self.jsString(videoId)), \(pendingStartMs / 1000))")
    }

    func play() { js("player && player.playVideo()") }
    func pause() { js("player && player.pauseVideo()") }

    func seek(toMs ms: Double) {
        currentTimeMs = ms
        lastTickDate = Date()
        guard isReady else {
            // Aún cargando: el vídeo empezará directamente en esa posición
            pendingStartMs = ms
            cue()
            return
        }
        js("player && player.seekTo(\(ms / 1000), true)")
    }

    func setRate(_ value: Double) {
        rate = value
        js("player && player.setPlaybackRate(\(value))")
    }

    private func js(_ code: String) {
        webView.evaluateJavaScript(code + "; void 0", completionHandler: nil)
    }

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    // MARK: - Eventos

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let num: (String) -> Double? = { (body[$0] as? NSNumber)?.doubleValue }

        switch type {
        case "apiReady":
            apiReady = true
            cue()

        case "ready":
            isReady = true
            // Si llegó un seek mientras se creaba el reproductor, lo colocamos sin arrancarlo
            if pendingStartMs > 0, let videoId {
                js("player.cueVideoById({videoId:\(Self.jsString(videoId)),startSeconds:\(pendingStartMs / 1000)})")
            }
            pendingStartMs = 0
            if let d = num("duration"), d > 0 { durationMs = d; onDuration?(d) }
            js("player.setPlaybackRate(\(rate))")

        case "duration":
            if let d = num("ms"), d > 0, d != durationMs { durationMs = d; onDuration?(d) }

        case "time":
            if let ms = num("ms") {
                currentTimeMs = ms
                lastTickDate = Date()
                onTime?(ms)
            }

        case "state":
            // 1 = playing, 2 = paused, 0 = ended. Ignoramos buffering (3) y cued (5)
            switch Int(num("state") ?? -1) {
            case 1:
                if !isPlaying { isPlaying = true; onPlayingChanged?(true) }
            case 0, 2:
                if isPlaying { isPlaying = false; onPlayingChanged?(false) }
            default: break
            }

        case "rate":
            if let r = num("rate") { rate = r }

        case "error":
            errorMessage = Self.describe(error: Int(num("code") ?? 0))

        default: break
        }
    }

    private static func describe(error code: Int) -> String {
        switch code {
        case 2: return "ID de vídeo no válido."
        case 5: return "El vídeo no se puede reproducir en este reproductor."
        case 100: return "El vídeo no existe o es privado."
        case 101, 150: return "El propietario no permite reproducir este vídeo fuera de YouTube. Prueba con otro."
        case 152, 153: return "YouTube rechazó el reproductor embebido (origen). Revisa el bundle id."
        default: return "Error de YouTube (\(code))."
        }
    }

    private static let html = """
    <!doctype html><html><head>
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
    <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{width:100%;height:100%}</style>
    </head><body><div id="p"></div>
    <script>
    const post=(t,o={})=>window.webkit.messageHandlers.yt.postMessage(Object.assign({type:t},o));
    let player=null, timer=null;
    function tick(){ if(player&&player.getCurrentTime) post('time',{ms:player.getCurrentTime()*1000}); }
    function onYouTubeIframeAPIReady(){ post('apiReady'); }
    window.unload=function(){
      clearInterval(timer); timer=null;
      if(player){ try{ player.destroy(); }catch(e){} player=null; }
      document.body.innerHTML='<div id="p"></div>';
    };
    window.cue=function(id,start){
      start=start||0;
      if(player && player.cueVideoById){ player.cueVideoById({videoId:id,startSeconds:start}); return; }
      if(player) return; // creándose: onReady lo colocará
      player=new YT.Player('p',{videoId:id,
        playerVars:{playsinline:1,rel:0,modestbranding:1,enablejsapi:1,origin:location.origin,start:Math.floor(start)},
        events:{
          onReady:()=>post('ready',{duration:player.getDuration()*1000}),
          onStateChange:(e)=>{
            post('state',{state:e.data});
            if(e.data===1){ if(!timer) timer=setInterval(tick,40); }
            else { clearInterval(timer); timer=null; tick(); }
            if(e.data===1||e.data===5) post('duration',{ms:player.getDuration()*1000});
          },
          onPlaybackRateChange:(e)=>post('rate',{rate:e.data}),
          onError:(e)=>post('error',{code:e.data})
        }});
    };
    </script>
    <script src="https://www.youtube.com/iframe_api"></script>
    </body></html>
    """
}

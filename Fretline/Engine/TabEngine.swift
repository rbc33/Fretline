import Foundation
import WebKit
import Observation

struct TrackInfo: Identifiable, Hashable {
    let index: Int
    let name: String
    let isPercussion: Bool
    var id: Int { index }
}

struct SyncProgress: Equatable {
    var count: Int
    var total: Int
}

struct SongsterrConversion {
    let gpData: Data
    let title: String
    let artist: String
    let videoId: String?
    let syncPoints: [SyncPoint]
}

/// Envuelve el WKWebView con alphaTab. Swift manda comandos (`window.fretline.*`)
/// y recibe eventos (`webkit.messageHandlers.fretline`).
@MainActor
@Observable
final class TabEngine: NSObject, WKScriptMessageHandler {
    let webView: WKWebView

    private(set) var isReady = false
    private(set) var isPlayerReady = false
    private(set) var isPlaying = false
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var tracks: [TrackInfo] = []
    private(set) var barCount = 0
    private(set) var currentTime: Double = 0   // ms
    private(set) var endTime: Double = 0       // ms
    private(set) var currentBar = 0
    private(set) var hasSelection = false
    private(set) var syncPoints: [SyncPoint] = []
    private(set) var syncProgress: SyncProgress?
    /// WebKit no deja arrancar el audio del sintetizador hasta que se toque la partitura
    private(set) var audioBlocked = false
    var lastError: String?

    // Medio externo (YouTube): alphaTab pide, nosotros reenviamos
    @ObservationIgnored var onExternalPlay: (() -> Void)?
    @ObservationIgnored var onExternalPause: (() -> Void)?
    @ObservationIgnored var onExternalSeek: ((Double) -> Void)?
    @ObservationIgnored var onExternalRate: ((Double) -> Void)?
    @ObservationIgnored var onScoreLoaded: ((_ title: String, _ artist: String) -> Void)?
    @ObservationIgnored var onSyncPointsChanged: (([SyncPoint]) -> Void)?
    /// Barra espaciadora pulsada con el foco dentro de la partitura (Mac)
    @ObservationIgnored var onSpace: (() -> Void)?

    @ObservationIgnored private var currentMode: PlaybackMode = .synth
    @ObservationIgnored private var pending: [(String, [Any])] = []
    @ObservationIgnored private var conversions: [String: CheckedContinuation<SongsterrConversion, Error>] = [:]

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalSchemeHandler(), forURLScheme: LocalSchemeHandler.scheme)
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        config.mediaTypesRequiringUserActionForPlayback = []
        let controller = WKUserContentController()
        config.userContentController = controller

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        super.init()

        controller.add(WeakScriptMessageHandler(self), name: "fretline")
        webView.isInspectable = true // Safari > Desarrollo > iPad para depurar
        #if os(iOS)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        #endif
        webView.load(URLRequest(url: LocalSchemeHandler.appURL("index.html")))
    }

    // MARK: - Comandos

    func loadSong(url: URL, syncPoints: [SyncPoint], mode: PlaybackMode) {
        self.syncPoints = syncPoints
        currentMode = mode
        isPlayerReady = false
        invoke("loadSong", [["url": url.absoluteString,
                             "syncPoints": syncPoints.map(\.dict),
                             "mode": mode.rawValue]])
    }

    func setMode(_ mode: PlaybackMode) {
        guard mode != currentMode else { return }
        currentMode = mode
        isPlayerReady = false
        isPlaying = false
        audioBlocked = false
        invoke("setMode", [mode.rawValue])
    }

    // La sesión de audio la gestiona WebKit; tocarla en cada play puede interrumpir el sintetizador
    func playPause() { invoke("playPause") }
    func play() { invoke("play") }
    func pause() { invoke("pause") }
    func stop() { invoke("stop") }
    func setSpeed(_ value: Double) { invoke("setSpeed", [value]) }
    func setLooping(_ on: Bool) { invoke("setLooping", [on]) }
    func clearSelection() { invoke("clearSelection"); hasSelection = false }
    func setMetronome(_ on: Bool) { invoke("setMetronome", [on]) }
    func setCountIn(_ on: Bool) { invoke("setCountIn", [on]) }
    func showTracks(_ indices: [Int]) { invoke("showTracks", [indices]) }
    func setMute(_ index: Int, _ on: Bool) { invoke("setMute", [index, on]) }
    func setSolo(_ index: Int, _ on: Bool) { invoke("setSolo", [index, on]) }
    func setLayout(horizontal: Bool) { invoke("setLayout", [horizontal ? "horizontal" : "page"]) }
    func setScale(_ scale: Double) { invoke("setScale", [scale]) }

    // YouTube -> alphaTab
    func externalTime(_ ms: Double) { invoke("externalTime", [ms], queueIfNotReady: false) }
    func externalDuration(_ ms: Double) { invoke("externalDuration", [ms]) }
    func externalState(playing: Bool) { invoke("externalState", [playing]) }

    // Sincronización
    func markNextBar(atMs ms: Double) { invoke("markNextBar", [ms]) }
    func quickSync(atMs ms: Double) { invoke("quickSync", [ms]) }
    func undoLastMark() { invoke("undoLastMark") }
    func clearSync() { invoke("clearSync"); syncProgress = nil }
    func nudgeSync(_ deltaMs: Double) { invoke("nudgeSync", [deltaMs]) }

    func convertSongsterr(meta: [String: Any], parts: [Any], videos: [[String: Any]]) async throws -> SongsterrConversion {
        let requestId = UUID().uuidString
        let payload: [String: Any] = ["requestId": requestId, "meta": meta, "parts": parts, "videos": videos]
        return try await withCheckedThrowingContinuation { continuation in
            conversions[requestId] = continuation
            invoke("convertSongsterr", [payload])
        }
    }

    private func invoke(_ fn: String, _ args: [Any] = [], queueIfNotReady: Bool = true) {
        guard isReady else {
            if queueIfNotReady { pending.append((fn, args)) }
            return
        }
        webView.callAsyncJavaScript("window.fretline[fn](...args); return null;",
                                    arguments: ["fn": fn, "args": args],
                                    in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result {
                self?.lastError = "JS \(fn): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Eventos desde JS

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let num: (String) -> Double? = { (body[$0] as? NSNumber)?.doubleValue }

        switch type {
        case "ready":
            isReady = true
            let queued = pending
            pending.removeAll()
            queued.forEach { invoke($0.0, $0.1) }

        case "scoreLoaded":
            title = body["title"] as? String ?? ""
            artist = body["artist"] as? String ?? ""
            barCount = Int(num("barCount") ?? 0)
            tracks = (body["tracks"] as? [[String: Any]] ?? []).compactMap { t in
                guard let i = (t["index"] as? NSNumber)?.intValue else { return nil }
                return TrackInfo(index: i, name: t["name"] as? String ?? "Pista \(i + 1)",
                                 isPercussion: t["isPercussion"] as? Bool ?? false)
            }
            onScoreLoaded?(title, artist)

        case "playerReady":
            isPlayerReady = true

        case "playerState":
            isPlaying = body["playing"] as? Bool ?? false

        case "key":
            if body["key"] as? String == "space" { onSpace?() }

        case "audioBlocked":
            audioBlocked = true

        case "audioUnblocked":
            audioBlocked = false

        case "position":
            currentTime = num("currentTime") ?? 0
            endTime = num("endTime") ?? 0

        case "bar":
            currentBar = Int(num("barIndex") ?? 0)

        case "selection":
            hasSelection = body["hasSelection"] as? Bool ?? false

        case "syncPoints":
            let points = (body["points"] as? [[String: Any]] ?? []).compactMap(SyncPoint.init(dict:))
            syncPoints = points
            if let total = syncProgress?.total { syncProgress = SyncProgress(count: points.count, total: total) }
            onSyncPointsChanged?(points)

        case "syncMarked":
            syncProgress = SyncProgress(count: Int(num("count") ?? 0), total: Int(num("total") ?? 0))

        case "syncMarkDone":
            let total = Int(num("total") ?? 0)
            syncProgress = SyncProgress(count: total, total: total)

        case "externalPlay": onExternalPlay?()
        case "externalPause": onExternalPause?()
        case "externalSeek": if let ms = num("ms") { onExternalSeek?(ms) }
        case "externalRate": if let rate = num("rate") { onExternalRate?(rate) }

        case "songsterrConverted":
            guard let id = body["requestId"] as? String, let continuation = conversions.removeValue(forKey: id) else { return }
            if let error = body["error"] as? String {
                continuation.resume(throwing: SongsterrError.conversion(error))
            } else if let b64 = body["gpBase64"] as? String, let data = Data(base64Encoded: b64) {
                let points = (body["syncPoints"] as? [[String: Any]] ?? []).compactMap(SyncPoint.init(dict:))
                continuation.resume(returning: SongsterrConversion(gpData: data,
                                                                   title: body["title"] as? String ?? "",
                                                                   artist: body["artist"] as? String ?? "",
                                                                   videoId: body["videoId"] as? String,
                                                                   syncPoints: points))
            } else {
                continuation.resume(throwing: SongsterrError.conversion("Respuesta vacía"))
            }

        case "error":
            lastError = body["message"] as? String

        default:
            break
        }
    }
}

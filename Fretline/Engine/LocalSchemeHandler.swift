import Foundation
import WebKit

/// Sirve la capa web empaquetada y las canciones de la biblioteca a través de `fretline://`.
/// - fretline://app/<ruta>          -> carpeta Web/ del bundle (alphaTab, SoundFont, app.js…)
/// - fretline://app/__songs/<file>  -> Documents/Songs/<file>
/// Todo cuelga del mismo origen (fretline://app) para no depender de CORS entre hosts.
/// Un esquema propio (en lugar de file://) permite módulos ES, workers y fetch con CORS.
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "fretline"

    static func appURL(_ path: String) -> URL {
        URL(string: "\(scheme)://app/\(path)")!
    }

    static func songURL(_ fileName: String) -> URL {
        let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        return URL(string: "\(scheme)://app/__songs/\(encoded)")!
    }

    private static let webRoot: URL? = Bundle.main.url(forResource: "Web", withExtension: nil)

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let host = url.host else {
            return fail(urlSchemeTask, status: 400)
        }
        guard host == "app" else { return fail(urlSchemeTask, status: 404) }
        var relative = String(url.path.drop(while: { $0 == "/" }))
        let base: URL?
        if relative.hasPrefix("__songs/") {
            relative.removeFirst("__songs/".count)
            base = SongLibrary.songsDirectory
        } else {
            base = Self.webRoot
        }
        guard let base else { return fail(urlSchemeTask, status: 404) }

        let fileURL = base.appending(path: relative).standardizedFileURL
        // Evita salir de la carpeta raíz (../)
        guard fileURL.path.hasPrefix(base.standardizedFileURL.path) else {
            return fail(urlSchemeTask, status: 403)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let headers = [
                "Content-Type": Self.mimeType(for: fileURL.pathExtension),
                "Content-Length": String(data.count),
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "no-cache",
            ]
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            fail(urlSchemeTask, status: 404)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask, status: Int) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Access-Control-Allow-Origin": "*"])!
        task.didReceive(response)
        task.didReceive(Data())
        task.didFinish()
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "otf": return "font/otf"
        case "svg": return "image/svg+xml"
        case "xml", "musicxml": return "application/xml"
        default: return "application/octet-stream"
        }
    }
}

/// Evita el ciclo de retención WKUserContentController -> handler.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

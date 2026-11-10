import Foundation
import SwiftData
import Observation

// ⚠️ Songsterr no tiene API pública. Estos endpoints son los que usa su propio visor web
// y pueden cambiar sin aviso. Uso personal: descargar contenido de Songsterr va contra sus
// términos de uso. Todo lo específico de Songsterr está aislado en este archivo y en
// Web/songsterr/convert.js para poder quitarlo o arreglarlo fácilmente.

enum SongsterrError: LocalizedError {
    case invalidURL
    case http(Int, String)
    case badResponse(String)
    case conversion(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "No reconozco esa URL. Pega un enlace de songsterr.com (…-s12345) o el número de la canción."
        case .http(let code, let what): return "Songsterr respondió \(code) al pedir \(what)."
        case .badResponse(let what): return "Respuesta inesperada de Songsterr (\(what)). Puede que hayan cambiado su formato."
        case .conversion(let msg): return "No se pudo convertir la tab: \(msg)"
        }
    }
}

struct SongsterrClient {
    struct Meta {
        let songId: Int
        let revisionId: Int
        let title: String
        let artist: String
        let image: String
        let partIds: [Int]
        let raw: [String: Any]
    }

    struct Video {
        let videoId: String
        let points: [Double] // segundos, uno por compás tocado
    }

    private static let cdnHosts = [
        "dqsljvtekg760.cloudfront.net",
        "d3d3l6a6rcgkaf.cloudfront.net",
        "d3rrfvx08uyjp1.cloudfront.net",
    ]

    let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        ]
        return URLSession(configuration: config)
    }()

    /// Acepta "https://www.songsterr.com/a/wsa/artista-cancion-tab-s12345", "…-s12345t2" o "12345".
    static func songId(from input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = Int(trimmed) { return id }
        guard let regex = try? NSRegularExpression(pattern: #"-s(\d+)(?:t\d+)?(?:[/?#]|$)"#) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              let r = Range(match.range(at: 1), in: trimmed) else { return nil }
        return Int(trimmed[r])
    }

    func fetchMeta(songId: Int) async throws -> Meta {
        let json = try await getJSON("https://www.songsterr.com/api/meta/\(songId)", what: "metadatos")
        guard let dict = json as? [String: Any],
              let revisionId = (dict["revisionId"] as? NSNumber)?.intValue else {
            throw SongsterrError.badResponse("meta")
        }
        let tracks = dict["tracks"] as? [[String: Any]] ?? []
        let partIds = tracks.enumerated().map { i, t in (t["partId"] as? NSNumber)?.intValue ?? i }
        return Meta(songId: songId,
                    revisionId: revisionId,
                    title: dict["title"] as? String ?? "",
                    artist: dict["artist"] as? String ?? "",
                    image: dict["image"] as? String ?? "",
                    partIds: partIds.isEmpty ? [0] : partIds,
                    raw: dict)
    }

    func fetchPart(meta: Meta, partId: Int) async throws -> [String: Any] {
        var lastError: Error = SongsterrError.badResponse("pista \(partId)")
        for host in Self.cdnHosts {
            do {
                let json = try await getJSON("https://\(host)/\(meta.songId)/\(meta.revisionId)/\(meta.image)/\(partId).json",
                                             what: "la pista \(partId)")
                if var dict = json as? [String: Any] {
                    // El nombre e instrumento suelen venir en meta.tracks
                    if let tracks = meta.raw["tracks"] as? [[String: Any]], partId < tracks.count {
                        let t = tracks[partId]
                        if dict["name"] == nil { dict["name"] = t["name"] ?? t["title"] ?? t["instrument"] }
                        if dict["instrumentId"] == nil { dict["instrumentId"] = t["instrumentId"] }
                        if dict["tuning"] == nil { dict["tuning"] = t["tuning"] }
                    }
                    return dict
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func fetchVideo(meta: Meta) async -> Video? {
        guard let json = try? await getJSON("https://www.songsterr.com/api/video-points/\(meta.songId)/\(meta.revisionId)/list",
                                            what: "vídeos"),
              let list = json as? [[String: Any]] else { return nil }
        let candidates = list.compactMap { item -> (Video, Bool)? in
            guard let id = item["videoId"] as? String,
                  let points = (item["points"] as? [NSNumber])?.map(\.doubleValue), !points.isEmpty else { return nil }
            let preferred = (item["status"] as? String) == "done" && item["feature"] == nil
            return (Video(videoId: id, points: points), preferred)
        }
        return (candidates.first(where: { $0.1 }) ?? candidates.first)?.0
    }

    private func getJSON(_ urlString: String, what: String) async throws -> Any {
        guard let url = URL(string: urlString) else { throw SongsterrError.invalidURL }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SongsterrError.http(http.statusCode, what)
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}

/// Descarga una canción de Songsterr, la convierte a .gp (con alphaTab en un WebView oculto)
/// y la guarda en la biblioteca con su vídeo y puntos de sincronización.
@MainActor
@Observable
final class SongsterrImporter {
    private(set) var status: String?
    private(set) var isWorking = false
    @ObservationIgnored private lazy var engine = TabEngine()
    @ObservationIgnored private let client = SongsterrClient()

    func importSong(from input: String, into context: ModelContext) async throws -> Song {
        guard let songId = SongsterrClient.songId(from: input) else { throw SongsterrError.invalidURL }
        isWorking = true
        defer { isWorking = false; status = nil }

        status = "Buscando la canción…"
        let meta = try await client.fetchMeta(songId: songId)

        var parts: [Any] = []
        for (n, partId) in meta.partIds.enumerated() {
            status = "Descargando pista \(n + 1) de \(meta.partIds.count)…"
            parts.append(try await client.fetchPart(meta: meta, partId: partId))
        }

        status = "Buscando vídeo sincronizado…"
        let video = await client.fetchVideo(meta: meta)

        status = "Convirtiendo a Guitar Pro…"
        let result = try await engine.convertSongsterr(meta: ["title": meta.title, "artist": meta.artist],
                                                       parts: parts,
                                                       videoPoints: video?.points)

        let fileName = try SongLibrary.store(data: result.gpData, ext: "gp")
        let song = Song(title: meta.title.isEmpty ? result.title : meta.title,
                        artist: meta.artist.isEmpty ? result.artist : meta.artist,
                        fileName: fileName,
                        source: "songsterr",
                        songsterrId: songId,
                        youtubeVideoId: video?.videoId,
                        syncPoints: result.syncPoints)
        context.insert(song)
        try? context.save()
        return song
    }
}

import Foundation
import SwiftData

/// Una entrada del historial de importaciones. Se conserva aunque la canción
/// se borre de la biblioteca, para poder volver a importarla.
@Model
final class ImportRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var artist: String
    /// "file" | "songsterr"
    var source: String
    var songsterrId: Int?
    /// Nombre original del archivo importado (solo para archivos)
    var originalFileName: String?
    var importedAt: Date
    /// `Song.id` de la canción creada (puede que ya no exista)
    var songId: UUID?

    init(song: Song, originalFileName: String? = nil) {
        self.id = UUID()
        self.title = song.title
        self.artist = song.artist
        self.source = song.source
        self.songsterrId = song.songsterrId
        self.originalFileName = originalFileName
        self.importedAt = .now
        self.songId = song.id
    }

    var isSongsterr: Bool { source == "songsterr" }

    var songsterrURL: URL? {
        songsterrId.flatMap { URL(string: "https://www.songsterr.com/a/wsa/tab-s\($0)") }
    }
}

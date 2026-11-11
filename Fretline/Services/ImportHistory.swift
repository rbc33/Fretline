import Foundation
import SwiftData

enum ImportHistory {
    /// Cuando un archivo se abre por primera vez se descubre su título real: lo copiamos al historial.
    static func updateTitle(for song: Song, in context: ModelContext) {
        let songId = song.id
        let descriptor = FetchDescriptor<ImportRecord>(predicate: #Predicate { $0.songId == songId })
        for record in (try? context.fetch(descriptor)) ?? [] {
            record.title = song.title
            record.artist = song.artist
        }
        try? context.save()
    }

    /// Las canciones importadas antes de existir el historial entran con su fecha original (una sola vez).
    static func backfillIfNeeded(in context: ModelContext) {
        let key = "importHistoryBackfilled"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let songs = (try? context.fetch(FetchDescriptor<Song>())) ?? []
        guard !songs.isEmpty, ((try? context.fetchCount(FetchDescriptor<ImportRecord>())) ?? 0) == 0 else { return }
        for song in songs {
            let record = ImportRecord(song: song)
            record.importedAt = song.addedAt
            context.insert(record)
        }
        try? context.save()
    }

    static func clear(in context: ModelContext) {
        try? context.delete(model: ImportRecord.self)
        try? context.save()
    }
}

import Foundation
import SwiftData
import UniformTypeIdentifiers

enum SongLibrary {
    static let supportedExtensions: Set<String> = ["gp", "gp3", "gp4", "gp5", "gpx", "musicxml", "xml"]

    static var importTypes: [UTType] {
        [
            UTType(importedAs: "com.rbc33.fretline.guitarpro"),
            UTType(importedAs: "com.rbc33.fretline.musicxml", conformingTo: .xml),
            .xml,
        ]
    }

    static var songsDirectory: URL {
        let dir = URL.documentsDirectory.appending(path: "Songs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    enum ImportError: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): return "Unsupported format: .\(ext)"
            }
        }
    }

    /// Copia un archivo externo (Archivos, AirDrop, "Abrir con…") a la biblioteca.
    @discardableResult
    static func importFile(at url: URL, into context: ModelContext) throws -> Song {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw ImportError.unsupported(ext) }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let fileName = try store(data: data, ext: ext)
        let song = Song(title: url.deletingPathExtension().lastPathComponent,
                        fileName: fileName,
                        titleIsPlaceholder: true)
        context.insert(song)
        context.insert(ImportRecord(song: song, originalFileName: url.lastPathComponent))
        try? context.save()
        return song
    }

    static func store(data: Data, ext: String) throws -> String {
        let fileName = "\(UUID().uuidString).\(ext)"
        try data.write(to: songsDirectory.appending(path: fileName), options: .atomic)
        return fileName
    }

    /// Guarda la tab editada como archivo nuevo (Guitar Pro 7). El original se conserva aparte
    /// la primera vez, para poder volver a él; las versiones editadas anteriores se borran.
    static func saveEdited(_ song: Song, data: Data, into context: ModelContext) throws {
        let previous = song.fileName
        let newName = try store(data: data, ext: "gp")
        if song.originalFileName == nil && !song.isCreatedHere {
            song.originalFileName = previous          // primera edición: guardamos el original
            song.originalSyncPointsData = song.syncPointsData
        } else {
            try? FileManager.default.removeItem(at: songsDirectory.appending(path: previous))
        }
        song.fileName = newName
        song.edits = []                               // los cambios de cuerda ya van dentro del archivo
        try? context.save()
    }

    /// Vuelve al archivo original y borra la versión editada
    static func revertToOriginal(_ song: Song, in context: ModelContext) {
        guard let original = song.originalFileName else { return }
        try? FileManager.default.removeItem(at: song.fileURL)
        song.fileName = original
        song.originalFileName = nil
        song.syncPointsData = song.originalSyncPointsData
        song.originalSyncPointsData = nil
        song.edits = []
        try? context.save()
    }

    static func delete(_ song: Song, from context: ModelContext) {
        try? FileManager.default.removeItem(at: song.fileURL)
        if let original = song.originalFileName {
            try? FileManager.default.removeItem(at: songsDirectory.appending(path: original))
        }
        context.delete(song)
        try? context.save()
    }
}

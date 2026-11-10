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
            case .unsupported(let ext): return "Formato no soportado: .\(ext)"
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
        try? context.save()
        return song
    }

    static func store(data: Data, ext: String) throws -> String {
        let fileName = "\(UUID().uuidString).\(ext)"
        try data.write(to: songsDirectory.appending(path: fileName), options: .atomic)
        return fileName
    }

    static func delete(_ song: Song, from context: ModelContext) {
        try? FileManager.default.removeItem(at: song.fileURL)
        context.delete(song)
        try? context.save()
    }
}

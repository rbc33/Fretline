import Foundation
import SwiftData
import Observation

/// Crea una tab nueva vacía (con alphaTab en un WebView oculto) y la añade a la biblioteca.
@MainActor
@Observable
final class TabCreator {
    struct Options {
        var title = ""
        var artist = ""
        var tuningId = "guitar-standard"
        var tempo = 120
        var numerator = 4
        var denominator = 4
        var bars = 8
    }

    /// Afinaciones disponibles (los ids coinciden con TUNINGS en Web/editor.js)
    static let tunings: [(id: String, name: String)] = [
        ("guitar-standard", "Guitar · Standard (E A D G B E)"),
        ("guitar-dropd", "Guitar · Drop D (D A D G B E)"),
        ("guitar-halfdown", "Guitar · Half step down (E♭)"),
        ("guitar-dadgad", "Guitar · DADGAD"),
        ("guitar-7", "7-string guitar (B E A D G B E)"),
        ("bass-4", "Bass · 4 strings (E A D G)"),
        ("bass-5", "Bass · 5 strings (B E A D G)"),
    ]

    private(set) var isWorking = false
    @ObservationIgnored private lazy var engine = TabEngine()

    func create(_ options: Options, into context: ModelContext) async throws -> Song {
        isWorking = true
        defer { isWorking = false }
        let title = options.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : options.title
        let data = try await engine.createScore([
            "title": title,
            "artist": options.artist,
            "tuningId": options.tuningId,
            "tempo": options.tempo,
            "numerator": options.numerator,
            "denominator": options.denominator,
            "bars": options.bars,
        ])
        let fileName = try SongLibrary.store(data: data, ext: "gp")
        let song = Song(title: title, artist: options.artist, fileName: fileName, source: "new")
        context.insert(song)
        try? context.save()
        return song
    }
}

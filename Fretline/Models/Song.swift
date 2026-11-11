import Foundation
import SwiftData

enum PlaybackMode: String, CaseIterable, Identifiable {
    case synth, youtube
    var id: String { rawValue }
    var label: String { self == .synth ? "Synth" : "YouTube" }
}

/// Igual que `FlatSyncPoint` de alphaTab.
struct SyncPoint: Codable, Hashable {
    var barIndex: Int
    var barPosition: Double
    var barOccurence: Int
    var millisecondOffset: Double

    init(barIndex: Int, barPosition: Double = 0, barOccurence: Int = 0, millisecondOffset: Double) {
        self.barIndex = barIndex
        self.barPosition = barPosition
        self.barOccurence = barOccurence
        self.millisecondOffset = millisecondOffset
    }

    init?(dict: [String: Any]) {
        guard let bar = (dict["barIndex"] as? NSNumber)?.intValue,
              let ms = (dict["millisecondOffset"] as? NSNumber)?.doubleValue else { return nil }
        barIndex = bar
        barPosition = (dict["barPosition"] as? NSNumber)?.doubleValue ?? 0
        barOccurence = (dict["barOccurence"] as? NSNumber)?.intValue ?? 0
        millisecondOffset = ms
    }

    var dict: [String: Any] {
        ["barIndex": barIndex, "barPosition": barPosition, "barOccurence": barOccurence, "millisecondOffset": millisecondOffset]
    }
}

@Model
final class Song {
    @Attribute(.unique) var id: UUID
    var title: String
    var artist: String
    /// Nombre del archivo dentro de Documents/Songs
    var fileName: String
    /// "file" | "songsterr"
    var source: String
    var songsterrId: Int?
    var youtubeVideoId: String?
    var syncPointsData: Data?
    var lastSpeed: Double
    var favorite: Bool
    var addedAt: Date
    var lastOpenedAt: Date?
    /// true mientras el título sea el nombre del archivo (se sustituye por el de la partitura al abrirla)
    var titleIsPlaceholder: Bool

    init(title: String, artist: String = "", fileName: String, source: String = "file",
         songsterrId: Int? = nil, youtubeVideoId: String? = nil, syncPoints: [SyncPoint] = [],
         titleIsPlaceholder: Bool = false) {
        self.id = UUID()
        self.title = title
        self.artist = artist
        self.fileName = fileName
        self.source = source
        self.songsterrId = songsterrId
        self.youtubeVideoId = youtubeVideoId
        self.syncPointsData = syncPoints.isEmpty ? nil : try? JSONEncoder().encode(syncPoints)
        self.lastSpeed = 1.0
        self.favorite = false
        self.addedAt = .now
        self.titleIsPlaceholder = titleIsPlaceholder
    }

    var syncPoints: [SyncPoint] {
        get {
            guard let data = syncPointsData else { return [] }
            return (try? JSONDecoder().decode([SyncPoint].self, from: data)) ?? []
        }
        set {
            syncPointsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }

    var fileURL: URL { SongLibrary.songsDirectory.appending(path: fileName) }
}

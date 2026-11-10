import SwiftUI
import SwiftData
import AVFoundation

@main
struct FretlineApp: App {
    init() {
        // .playback: suena aunque el iPad esté en silencio y sigue con la pantalla bloqueada
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
        .modelContainer(for: Song.self)
    }
}

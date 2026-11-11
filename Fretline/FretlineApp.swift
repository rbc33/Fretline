import SwiftUI
import SwiftData
#if os(iOS)
import AVFoundation
#endif

@main
struct FretlineApp: App {
    init() {
        #if os(iOS)
        // .playback: suena aunque el iPad esté en silencio y sigue con la pantalla bloqueada
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
        .modelContainer(for: Song.self)
        #if os(macOS)
        .defaultSize(width: 1280, height: 860)
        .windowToolbarStyle(.unified)
        #endif
    }
}

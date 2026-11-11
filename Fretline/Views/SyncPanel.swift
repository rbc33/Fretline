import SwiftUI

/// Editor de sincronización tab <-> vídeo.
/// - Tap-along: con el vídeo sonando, toca (o pulsa espacio / un pedal) en el primer tiempo de cada compás.
/// - Rápido: marca solo dónde empieza el compás 1; el resto se calcula con el tempo de la partitura.
/// Los puntos se guardan solos en la canción en cuanto cambian.
struct SyncPanel: View {
    let engine: TabEngine
    let youtube: YouTubePlayer
    var onDone: () -> Void

    @State private var confirmClear = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync with video").font(.headline)
                Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: 280, alignment: .leading)

            Spacer()

            Button {
                markBar()
            } label: {
                Label("Mark bar", systemImage: "hand.tap.fill")
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            .help("Mark the start of the next bar at the current video time (Space)")

            Button("Bar 1 = now", systemImage: "flag.fill") {
                engine.quickSync(atMs: youtube.estimatedTimeMs)
            }
            .help("Quick sync: mark where bar 1 starts and the rest follows the tempo")

            HStack(spacing: 4) {
                Button { engine.nudgeSync(-50) } label: { Text("−50 ms").monospacedDigit() }
                    .help("Move every sync point 50 ms earlier")
                Button { engine.nudgeSync(50) } label: { Text("+50 ms").monospacedDigit() }
                    .help("Move every sync point 50 ms later")
            }
            .buttonStyle(.bordered)
            .disabled(engine.syncPoints.isEmpty)

            Button { engine.undoLastMark() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(engine.syncPoints.isEmpty)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo the last mark (⌘Z)")

            Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
                .disabled(engine.syncPoints.isEmpty)
                .help("Delete all sync points")
                .confirmationDialog("Delete all sync points?", isPresented: $confirmClear) {
                    Button("Delete", role: .destructive) { engine.clearSync() }
                }

            Button("Done", action: onDone).bold()
                .help("Close the sync editor (changes are saved automatically)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var hint: String {
        if !youtube.isPlaying && engine.syncPoints.isEmpty {
            return "Press play, then tap “Mark bar” (or Space / pedal) on beat 1 of every bar."
        }
        if let p = engine.syncProgress {
            return p.count >= p.total ? "All \(p.total) bars marked." : "\(p.count) of \(p.total) bars marked."
        }
        return "\(engine.syncPoints.count) sync points."
    }

    private func markBar() {
        guard youtube.isPlaying else {
            engine.play() // el primer toque arranca el vídeo
            return
        }
        engine.markNextBar(atMs: youtube.estimatedTimeMs)
    }
}

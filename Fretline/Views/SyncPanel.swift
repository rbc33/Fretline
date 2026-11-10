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
                Text("Sincronizar con el vídeo").font(.headline)
                Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: 280, alignment: .leading)

            Spacer()

            Button {
                markBar()
            } label: {
                Label("Marcar compás", systemImage: "hand.tap.fill")
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])

            Button("Compás 1 = ahora", systemImage: "flag.fill") {
                engine.quickSync(atMs: youtube.estimatedTimeMs)
            }
            .help("Modo rápido: solo marca el inicio; el resto se calcula con el tempo")

            HStack(spacing: 4) {
                Button { engine.nudgeSync(-50) } label: { Text("−50 ms").monospacedDigit() }
                Button { engine.nudgeSync(50) } label: { Text("+50 ms").monospacedDigit() }
            }
            .buttonStyle(.bordered)
            .disabled(engine.syncPoints.isEmpty)

            Button { engine.undoLastMark() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(engine.syncPoints.isEmpty)
                .keyboardShortcut("z", modifiers: .command)

            Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
                .disabled(engine.syncPoints.isEmpty)
                .confirmationDialog("¿Borrar todos los puntos de sincronización?", isPresented: $confirmClear) {
                    Button("Borrar", role: .destructive) { engine.clearSync() }
                }

            Button("Listo", action: onDone).bold()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var hint: String {
        if !youtube.isPlaying && engine.syncPoints.isEmpty {
            return "Dale a play y toca «Marcar compás» (o espacio/pedal) en el primer tiempo de cada compás."
        }
        if let p = engine.syncProgress {
            return p.count >= p.total ? "Todos los compases marcados (\(p.total))." : "Marcados \(p.count) de \(p.total) compases."
        }
        return "\(engine.syncPoints.count) puntos de sincronización."
    }

    private func markBar() {
        guard youtube.isPlaying else {
            engine.play() // el primer toque arranca el vídeo
            return
        }
        engine.markNextBar(atMs: youtube.estimatedTimeMs)
    }
}

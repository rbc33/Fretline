import SwiftUI

struct TracksSheet: View {
    let engine: TabEngine
    @Environment(\.dismiss) private var dismiss

    // Estado local (alphaTab no nos devuelve mute/solo); se guarda por índice de pista
    @State private var visible: Set<Int> = []
    @State private var muted: Set<Int> = []
    @State private var solo: Set<Int> = []
    @State private var initialized = false

    var body: some View {
        NavigationStack {
            List(engine.tracks) { track in
                HStack {
                    Button {
                        toggleVisible(track.index)
                    } label: {
                        Image(systemName: visible.contains(track.index) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)

                    Image(systemName: track.isPercussion ? "music.quarternote.3" : "guitars")
                        .foregroundStyle(.secondary)
                    Text(track.name)
                    Spacer()

                    Toggle(isOn: binding(for: track.index, in: $muted, apply: engine.setMute)) {
                        Text("M").bold().frame(width: 22)
                    }
                    .toggleStyle(.button)
                    .tint(.red)

                    Toggle(isOn: binding(for: track.index, in: $solo, apply: engine.setSolo)) {
                        Text("S").bold().frame(width: 22)
                    }
                    .toggleStyle(.button)
                    .tint(.green)
                }
            }
            .sheetSize(width: 440, height: 380)
            .navigationTitle("Pistas")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Hecho") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Toca el círculo para mostrar u ocultar pistas en la partitura. M = silenciar, S = solo.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
            }
            .onAppear {
                guard !initialized else { return }
                initialized = true
                if let first = engine.tracks.first { visible = [first.index] }
            }
        }
    }

    private func toggleVisible(_ index: Int) {
        if visible.contains(index) {
            guard visible.count > 1 else { return } // al menos una pista visible
            visible.remove(index)
        } else {
            visible.insert(index)
        }
        engine.showTracks(visible.sorted())
    }

    private func binding(for index: Int, in set: Binding<Set<Int>>, apply: @escaping (Int, Bool) -> Void) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(index) },
            set: { on in
                if on { set.wrappedValue.insert(index) } else { set.wrappedValue.remove(index) }
                apply(index, on)
            }
        )
    }
}

import SwiftUI

/// Panel del editor de tablatura. Con teclado (Mac o iPad con teclado) se puede editar casi
/// todo sin el panel: flechas para moverse, números para el traste, Supr para borrar…
struct EditorPanel: View {
    let engine: TabEngine
    /// Hay compases seleccionados (duplicar/borrar se aplican a la selección)
    var barSelection: ClosedRange<Int>?
    var canRevert: Bool
    var onKeep: () -> Void
    var onDiscard: () -> Void
    var onRevert: () -> Void
    var onDone: () -> Void

    @State private var showFretPad = false
    @State private var confirmRevert = false

    private var s: EditorState { engine.editorState }

    private static let durations: [(value: Int, label: String, help: String)] = [
        (1, "1", "Whole note"), (2, "½", "Half note"), (4, "¼", "Quarter note"),
        (8, "⅛", "Eighth note"), (16, "1/16", "Sixteenth note"), (32, "1/32", "Thirty-second note"),
    ]

    private static let techniques: [(id: String, label: String, help: String)] = [
        ("hammer", "H/P", "Hammer-on / pull-off to the next note on this string (H)"),
        ("slide", "/", "Slide to the next note, or slide out (S)"),
        ("bend", "B", "Full bend (B)"),
        ("palmMute", "PM", "Palm mute (P)"),
        ("letRing", "LR", "Let ring (L)"),
        ("vibrato", "~", "Vibrato (V)"),
        ("dead", "X", "Dead note (X)"),
    ]

    var body: some View {
        VStack(spacing: 10) {
            if !s.editable {
                Label("This track can’t be edited here (drums or no tablature). Show a guitar or bass track.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 14) {
                position
                Spacer(minLength: 8)
                navigation
                fretControls
                durationControls
            }
            HStack(spacing: 14) {
                techniqueControls
                Spacer(minLength: 8)
                beatAndBarControls
                history
                saveControls
                Button("Done", action: onDone).bold()
                    .help("Leave edit mode")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .disabled(!s.editable && !s.dirty)
    }

    // MARK: - Posición

    private var position: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Bar \(s.bar + 1) · Beat \(s.beat + 1) · String \(s.string)")
                .font(.headline.monospacedDigit())
            Text(s.fret.map { "Fret \($0)" } ?? (s.isRest ? "Rest. Type a number to add a note" : "Empty string. Type a number to add a note"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 220, alignment: .leading)
    }

    private var navigation: some View {
        HStack(spacing: 4) {
            Button { engine.editor("moveBeat", [-1]) } label: { Image(systemName: "chevron.left") }
                .help("Previous beat (←). Previous bar: ⌥←")
            VStack(spacing: 2) {
                Button { engine.editor("moveString", [1]) } label: { Image(systemName: "chevron.up") }
                    .help("String above (↑)")
                Button { engine.editor("moveString", [-1]) } label: { Image(systemName: "chevron.down") }
                    .help("String below (↓)")
            }
            .controlSize(.mini)
            Button { engine.editor("moveBeat", [1]) } label: { Image(systemName: "chevron.right") }
                .help("Next beat (→). Next bar: ⌥→")
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Traste

    private var fretControls: some View {
        HStack(spacing: 4) {
            Button { engine.editor("fretStep", [-1]) } label: { Image(systemName: "minus") }
                .disabled(s.fret == nil)
                .help("Fret down")
            Button {
                showFretPad = true
            } label: {
                Text(s.fret.map(String.init) ?? "Fret")
                    .monospacedDigit()
                    .frame(minWidth: 40)
            }
            .help("Choose a fret for this string (or just type the number)")
            .popover(isPresented: $showFretPad) { fretPad }
            Button { engine.editor("fretStep", [1]) } label: { Image(systemName: "plus") }
                .disabled(s.fret == nil)
                .help("Fret up")
            Button(role: .destructive) { engine.editor("deleteNote") } label: { Image(systemName: "delete.left") }
                .disabled(s.fret == nil)
                .help("Delete the note on this string (⌫)")
        }
        .buttonStyle(.bordered)
    }

    private var fretPad: some View {
        let columns = Array(repeating: GridItem(.fixed(44), spacing: 6), count: 5)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Fret on string \(s.string)").font(.headline)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(0...24, id: \.self) { fret in
                    Button {
                        engine.editor("setFret", [fret])
                        showFretPad = false
                    } label: {
                        Text("\(fret)").monospacedDigit().frame(width: 36, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .tint(s.fret == fret ? .accentColor : nil)
                }
            }
        }
        .padding(14)
    }

    // MARK: - Duración

    private var durationControls: some View {
        HStack(spacing: 4) {
            Picker("Duration", selection: Binding(get: { s.duration }, set: { engine.editor("setDuration", [$0]) })) {
                ForEach(Self.durations, id: \.value) { d in
                    Text(d.label).tag(d.value).help(d.help)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .help("Beat duration (+ shorter, − longer)")
            Toggle(isOn: Binding(get: { s.dotted }, set: { _ in engine.editor("toggleDot") })) { Text("•").bold() }
                .toggleStyle(.button)
                .help("Dotted (.)")
            Toggle(isOn: Binding(get: { s.triplet }, set: { _ in engine.editor("toggleTriplet") })) { Text("3").bold() }
                .toggleStyle(.button)
                .help("Triplet (T)")
        }
    }

    // MARK: - Técnicas

    private var techniqueControls: some View {
        HStack(spacing: 4) {
            ForEach(Self.techniques, id: \.id) { t in
                Toggle(isOn: Binding(get: { s.techniques?[t.id] ?? false },
                                     set: { _ in engine.editor("toggleTechnique", [t.id]) })) {
                    Text(t.label).font(.callout.bold()).frame(minWidth: 22)
                }
                .toggleStyle(.button)
                .disabled(s.fret == nil)
                .help(t.help)
            }
        }
    }

    // MARK: - Tiempos y compases

    private var beatAndBarControls: some View {
        HStack(spacing: 4) {
            Button { engine.editor("insertBeat") } label: { Image(systemName: "plus.rectangle") }
                .help("Insert a beat after this one (I)")
            Button { engine.editor("deleteBeat") } label: { Image(systemName: "minus.rectangle") }
                .help("Delete this beat")
            Menu {
                Button("Insert Empty Bar After", systemImage: "plus") { engine.editor("insertBar") }
                Button(barSelection.map { $0.count > 1 ? "Duplicate Bars \($0.lowerBound + 1)–\($0.upperBound + 1)" : "Duplicate Bar \($0.lowerBound + 1)" } ?? "Duplicate This Bar",
                       systemImage: "plus.square.on.square") { engine.editor("duplicateBars") }
                Divider()
                Button(barSelection.map { $0.count > 1 ? "Delete Bars \($0.lowerBound + 1)–\($0.upperBound + 1)" : "Delete Bar \($0.lowerBound + 1)" } ?? "Delete This Bar",
                       systemImage: "trash", role: .destructive) { engine.editor("deleteBars") }
            } label: {
                Label("Bars", systemImage: "square.split.2x1")
            }
            .help("Insert, duplicate or delete bars. Select bars first to duplicate or delete several")
        }
        .buttonStyle(.bordered)
    }

    private var history: some View {
        HStack(spacing: 4) {
            Button { engine.editor("undo") } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!s.canUndo)
                .help("Undo (⌘Z)")
            Button { engine.editor("redo") } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!s.canRedo)
                .help("Redo (⇧⌘Z)")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var saveControls: some View {
        if s.dirty {
            Button("Discard", role: .destructive, action: onDiscard)
                .help("Throw away the changes since the last save")
            Button("Keep Changes", systemImage: "pin.fill", action: onKeep)
                .buttonStyle(.borderedProminent)
                .help("Save the edited tab. Your original file is kept, and you can revert to it later")
        } else if canRevert {
            Button("Revert to Original", systemImage: "arrow.counterclockwise") { confirmRevert = true }
                .help("Go back to the tab as it was before you edited it")
                .confirmationDialog("Go back to the original tab? Your edits will be deleted.",
                                    isPresented: $confirmRevert, titleVisibility: .visible) {
                    Button("Revert to Original", role: .destructive, action: onRevert)
                }
        }
    }
}

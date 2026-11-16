import SwiftUI
import SwiftData

/// Hoja para empezar una tab desde cero.
struct NewTabSheet: View {
    var onCreated: (Song) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var creator = TabCreator()
    @State private var options = TabCreator.Options()
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Song") {
                    TextField("Title", text: $options.title, prompt: Text("Untitled"))
                    TextField("Artist", text: $options.artist, prompt: Text("Optional"))
                }
                Section("Instrument") {
                    Picker("Tuning", selection: $options.tuningId) {
                        ForEach(TabCreator.tunings, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
                Section {
                    Stepper("Tempo: \(options.tempo) BPM", value: $options.tempo, in: 30...300, step: 5)
                    HStack {
                        Text("Time signature")
                        Spacer()
                        Stepper("\(options.numerator)", value: $options.numerator, in: 1...16)
                            .fixedSize()
                        Text("/")
                        Picker("Beat", selection: $options.denominator) {
                            ForEach([2, 4, 8, 16], id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Stepper("Bars: \(options.bars)", value: $options.bars, in: 1...256)
                } header: {
                    Text("Rhythm")
                } footer: {
                    Text("You can add, duplicate or delete bars later in the editor.")
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .platformFormStyle()
            .sheetSize(width: 520, height: 520)
            .navigationTitle("New Tab")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(creator.isWorking)
                }
            }
        }
    }

    private func create() {
        errorMessage = nil
        Task {
            do {
                let song = try await creator.create(options, into: context)
                dismiss()
                onCreated(song)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

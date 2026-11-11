import SwiftUI
import SwiftData

struct SongsterrImportView: View {
    var onImported: (Song) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var importer = SongsterrImporter()
    @State private var input = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://www.songsterr.com/a/wsa/…-s12345", text: $input)
                        .urlInput()
                        .onSubmit(start)
                    if let clip = Clipboard.string, SongsterrClient.songId(from: clip) != nil, input.isEmpty {
                        Button("Pegar enlace del portapapeles", systemImage: "doc.on.clipboard") { input = clip }
                    }
                } header: {
                    Text("Enlace de Songsterr")
                } footer: {
                    Text("Se descargan todas las pistas, se convierten a Guitar Pro y, si Songsterr tiene un vídeo sincronizado, se importa también. Solo para uso personal.")
                }

                if let status = importer.status {
                    Section { HStack { ProgressView(); Text(status) } }
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .sheetSize(width: 520, height: 320)
            .navigationTitle("Importar de Songsterr")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Importar", action: start)
                        .disabled(importer.isWorking || SongsterrClient.songId(from: input) == nil)
                }
            }
            .interactiveDismissDisabled(importer.isWorking)
        }
    }

    private func start() {
        errorMessage = nil
        Task {
            do {
                let song = try await importer.importSong(from: input, into: context)
                dismiss()
                onImported(song)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

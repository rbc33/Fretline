import SwiftUI
import SwiftData

struct SongsterrImportView: View {
    var initialInput: String = ""
    var onImported: (Song) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var importer = SongsterrImporter()
    @State private var input = ""
    @Query(filter: #Predicate<ImportRecord> { $0.source == "songsterr" },
           sort: \ImportRecord.importedAt, order: .reverse)
    private var songsterrHistory: [ImportRecord]

    /// Últimas canciones de Songsterr, sin repetir
    private var recents: [ImportRecord] {
        var seen = Set<Int>()
        return songsterrHistory.filter { r in
            guard let id = r.songsterrId else { return false }
            return seen.insert(id).inserted
        }.prefix(5).map { $0 }
    }
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Enlace", text: $input, prompt: Text("https://www.songsterr.com/a/wsa/…-s12345"))
                        .labelsHidden()
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

                if input.isEmpty, !recents.isEmpty, !importer.isWorking {
                    Section("Importadas recientemente") {
                        ForEach(recents) { record in
                            Button {
                                if let id = record.songsterrId { input = String(id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.title).foregroundStyle(.primary)
                                    if !record.artist.isEmpty {
                                        Text(record.artist).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let status = importer.status {
                    Section { HStack { ProgressView(); Text(status) } }
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .platformFormStyle()
            .sheetSize(width: 520, height: recents.isEmpty ? 280 : 460)
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
            .onAppear { if input.isEmpty { input = initialInput } }
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

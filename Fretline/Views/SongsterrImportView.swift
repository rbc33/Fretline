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
                    TextField("Link", text: $input, prompt: Text("https://www.songsterr.com/a/wsa/…-s12345"))
                        .labelsHidden()
                        .urlInput()
                        .onSubmit(start)
                    if let clip = Clipboard.string, SongsterrClient.songId(from: clip) != nil, input.isEmpty {
                        Button("Paste link from clipboard", systemImage: "doc.on.clipboard") { input = clip }
                    }
                } header: {
                    Text("Songsterr link")
                } footer: {
                    Text("All tracks are downloaded and converted to Guitar Pro. If Songsterr has a synced video, it comes along too. For personal use only.")
                }

                if input.isEmpty, !recents.isEmpty, !importer.isWorking {
                    Section("Recently imported") {
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
            .navigationTitle("Import from Songsterr")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: start)
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

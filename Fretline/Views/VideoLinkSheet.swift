import SwiftUI

struct VideoLinkSheet: View {
    @Bindable var song: Song
    /// Devuelve el nuevo ID, o nil si se quitó el vídeo
    var onChange: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    private var parsedId: String? { YouTubeVideoID.parse(input) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Enlace", text: $input, prompt: Text("https://www.youtube.com/watch?v=…"))
                        .labelsHidden()
                        .urlInput()
                    if input.isEmpty, let clip = Clipboard.string, YouTubeVideoID.parse(clip) != nil {
                        Button("Pegar enlace del portapapeles", systemImage: "doc.on.clipboard") { input = clip }
                    }
                } header: {
                    Text("Vídeo de YouTube")
                } footer: {
                    Text(song.syncPoints.isEmpty
                         ? "Después usa «Sync» para marcar los compases sobre el vídeo."
                         : "Al cambiar de vídeo se borran los puntos de sincronización actuales.")
                }

                if song.youtubeVideoId != nil {
                    Section {
                        Button("Quitar vídeo", role: .destructive) {
                            song.youtubeVideoId = nil
                            song.syncPoints = []
                            onChange(nil)
                            dismiss()
                        }
                    }
                }
            }
            .platformFormStyle()
            .sheetSize(width: 520, height: 280)
            .navigationTitle("Vídeo")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        guard let id = parsedId else { return }
                        if id != song.youtubeVideoId {
                            song.youtubeVideoId = id
                            song.syncPoints = []
                        }
                        onChange(id)
                        dismiss()
                    }
                    .disabled(parsedId == nil)
                }
            }
            .onAppear {
                if let id = song.youtubeVideoId { input = "https://www.youtube.com/watch?v=\(id)" }
            }
        }
    }
}

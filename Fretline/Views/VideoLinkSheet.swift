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
                    TextField("Link", text: $input, prompt: Text("https://www.youtube.com/watch?v=…"))
                        .labelsHidden()
                        .urlInput()
                    if input.isEmpty, let clip = Clipboard.string, YouTubeVideoID.parse(clip) != nil {
                        Button("Paste link from clipboard", systemImage: "doc.on.clipboard") { input = clip }
                    }
                } header: {
                    Text("YouTube video")
                } footer: {
                    Text(song.syncPoints.isEmpty
                         ? "Then use “Sync” to mark the bars over the video."
                         : "Changing the video deletes the current sync points.")
                }

                if song.youtubeVideoId != nil {
                    Section {
                        Button("Remove Video", role: .destructive) {
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
            .navigationTitle("Video")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
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

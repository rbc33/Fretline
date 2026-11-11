import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Song.addedAt, order: .reverse) private var songs: [Song]

    @State private var search = ""
    @State private var showFileImporter = false
    @State private var showSongsterr = false
    @State private var showHistory = false
    /// Enlace con el que abrir la hoja de Songsterr (al reimportar desde el historial)
    @State private var songsterrPrefill = ""
    @State private var path: [Song] = []
    @State private var errorMessage: String?

    private var filtered: [Song] {
        guard !search.isEmpty else { return songs }
        return songs.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.artist.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if songs.isEmpty {
                    ContentUnavailableView {
                        Label("No songs yet", systemImage: "guitars")
                    } description: {
                        Text("Import a Guitar Pro file (.gp, .gp5, .gpx…) or a Songsterr tab.")
                    } actions: {
                        Button("Import File") { showFileImporter = true }.buttonStyle(.borderedProminent)
                        Button("From Songsterr") { songsterrPrefill = ""; showSongsterr = true }
                    }
                } else {
                    List {
                        ForEach(filtered) { song in
                            NavigationLink(value: song) { SongRow(song: song) }
                                .contextMenu {
                                    Button(song.favorite ? "Remove from Favorites" : "Favorite",
                                           systemImage: song.favorite ? "star.slash" : "star") { song.favorite.toggle() }
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        SongLibrary.delete(song, from: context)
                                    }
                                }
                        }
                        .onDelete { offsets in
                            offsets.map { filtered[$0] }.forEach { SongLibrary.delete($0, from: context) }
                        }
                    }
                    .searchable(text: $search, prompt: "Search songs or artists")
                }
            }
            .navigationTitle("Fretline")
            .navigationDestination(for: Song.self) { PlayerView(song: $0) }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("History", systemImage: "clock.arrow.circlepath") { showHistory = true }
                        .keyboardShortcut("y")
                    Button("Songsterr", systemImage: "arrow.down.circle") { songsterrPrefill = ""; showSongsterr = true }
                    Button("Import", systemImage: "square.and.arrow.down") { showFileImporter = true }
                        .keyboardShortcut("o")
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: SongLibrary.importTypes,
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): importFiles(urls)
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showSongsterr) {
                SongsterrImportView(initialInput: songsterrPrefill) { song in path = [song] }
            }
            .sheet(isPresented: $showHistory) {
                HistoryView(onOpen: { song in path = [song] },
                            onReimport: { id in
                                songsterrPrefill = String(id)
                                // Espera a que se cierre el historial antes de abrir la otra hoja
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showSongsterr = true }
                            })
            }
            .task { ImportHistory.backfillIfNeeded(in: context) }
            .onOpenURL { url in
                guard url.isFileURL else { return }
                importFiles([url], open: true)
            }
            .alert("Import failed", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func importFiles(_ urls: [URL], open: Bool = false) {
        var last: Song?
        for url in urls {
            do { last = try SongLibrary.importFile(at: url, into: context) }
            catch { errorMessage = error.localizedDescription }
        }
        if (open || urls.count == 1), let last { path = [last] }
    }
}

private struct SongRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: song.source == "songsterr" ? "music.note.list" : "doc.richtext")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.headline).lineLimit(1)
                if !song.artist.isEmpty {
                    Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if song.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            if song.youtubeVideoId != nil {
                Image(systemName: song.syncPoints.isEmpty ? "play.rectangle" : "play.rectangle.fill")
                    .foregroundStyle(song.syncPoints.isEmpty ? Color.secondary : Color.red)
                    .help(song.syncPoints.isEmpty ? "Video not synced" : "Video synced")
            }
        }
        .padding(.vertical, 4)
    }
}

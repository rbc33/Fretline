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

    // Búsqueda en Songsterr desde el mismo campo de búsqueda
    @State private var importer = SongsterrImporter()
    @State private var songsterrResults: [SongsterrClient.SearchResult] = []
    @State private var songsterrSearching = false
    @State private var songsterrError: String?
    @State private var importingId: Int?

    private var filtered: [Song] {
        guard !search.isEmpty else { return songs }
        return songs.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.artist.localizedCaseInsensitiveContains(search) }
    }

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if songs.isEmpty && search.isEmpty {
                    ContentUnavailableView {
                        Label("No songs yet", systemImage: "guitars")
                    } description: {
                        Text("Import a Guitar Pro file (.gp, .gp5, .gpx…), a Songsterr tab, or search Songsterr above.")
                    } actions: {
                        Button("Import File") { showFileImporter = true }.buttonStyle(.borderedProminent)
                        Button("From Songsterr") { songsterrPrefill = ""; showSongsterr = true }
                    }
                } else {
                    List {
                        if search.isEmpty {
                            librarySongs
                        } else {
                            if !filtered.isEmpty {
                                Section("In your library") { librarySongs }
                            }
                            songsterrSection
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search your library and Songsterr")
            .task(id: trimmedSearch) { await searchSongsterr(trimmedSearch) }
            .navigationTitle("Fretline")
            .navigationDestination(for: Song.self) { PlayerView(song: $0) }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("History", systemImage: "clock.arrow.circlepath") { showHistory = true }
                        .keyboardShortcut("y")
                        .help("Import history (⌘Y)")
                    Button("Songsterr", systemImage: "arrow.down.circle") { songsterrPrefill = ""; showSongsterr = true }
                        .help("Import a tab from a Songsterr link")
                    Button("Import", systemImage: "square.and.arrow.down") { showFileImporter = true }
                        .keyboardShortcut("o")
                        .help("Import a Guitar Pro or MusicXML file (⌘O)")
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

    // MARK: - Biblioteca

    private var librarySongs: some View {
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

    // MARK: - Songsterr

    @ViewBuilder
    private var songsterrSection: some View {
        Section {
            if trimmedSearch.count < 2 {
                Text("Type at least 2 characters to search Songsterr.").foregroundStyle(.secondary)
            } else if let songsterrError {
                Label(songsterrError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if songsterrResults.isEmpty {
                if songsterrSearching {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Searching Songsterr…") }
                        .foregroundStyle(.secondary)
                } else {
                    Text("No results on Songsterr.").foregroundStyle(.secondary)
                }
            }
            ForEach(songsterrResults) { result in
                songsterrRow(result)
            }
        } header: {
            HStack {
                Text("On Songsterr")
                if songsterrSearching && !songsterrResults.isEmpty { ProgressView().controlSize(.mini) }
            }
        }
    }

    private func songsterrRow(_ result: SongsterrClient.SearchResult) -> some View {
        let existing = songs.first { $0.songsterrId == result.songId }
        let isImporting = importingId == result.songId
        return Button {
            if let existing { path = [existing] } else { importFromSongsterr(result) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).font(.headline).lineLimit(1)
                    Text(isImporting ? (importer.status ?? "Importing…") : subtitle(result))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if isImporting {
                    ProgressView().controlSize(.small)
                } else if existing != nil {
                    Label("In library", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                        .help("Already in your library: open it")
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.tint)
                        .help("Import from Songsterr")
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(importingId != nil && !isImporting)
    }

    private func subtitle(_ r: SongsterrClient.SearchResult) -> String {
        let tracks = r.trackCount == 1 ? "1 track" : "\(r.trackCount) tracks"
        return r.artist.isEmpty ? tracks : "\(r.artist) · \(tracks)"
    }

    private func searchSongsterr(_ pattern: String) async {
        songsterrError = nil
        guard pattern.count >= 2 else {
            songsterrResults = []
            songsterrSearching = false
            return
        }
        songsterrSearching = true
        // Espera a que se deje de escribir; si cambia el texto, esta tarea se cancela
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        do {
            let results = try await SongsterrClient().search(pattern)
            guard !Task.isCancelled else { return }
            songsterrResults = results
        } catch {
            guard !Task.isCancelled else { return }
            songsterrResults = []
            songsterrError = "Couldn’t search Songsterr: \(error.localizedDescription)"
        }
        songsterrSearching = false
    }

    private func importFromSongsterr(_ result: SongsterrClient.SearchResult) {
        importingId = result.songId
        Task {
            defer { importingId = nil }
            do {
                let song = try await importer.importSong(from: String(result.songId), into: context)
                path = [song]
            } catch {
                errorMessage = error.localizedDescription
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

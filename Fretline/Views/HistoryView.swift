import SwiftUI
import SwiftData

/// Historial de canciones importadas (archivos y Songsterr), agrupado por día.
/// Las entradas se conservan aunque la canción se borre de la biblioteca.
struct HistoryView: View {
    /// Abrir una canción que sigue en la biblioteca
    var onOpen: (Song) -> Void
    /// Volver a importar de Songsterr (recibe el id de la canción)
    var onReimport: (Int) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Query(sort: \ImportRecord.importedAt, order: .reverse) private var records: [ImportRecord]
    @Query private var songs: [Song]

    @State private var search = ""
    @State private var filter: SourceFilter = .all
    @State private var confirmClear = false

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all, songsterr, file
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .songsterr: return "Songsterr"
            case .file: return "Files"
            }
        }
    }

    private var songsById: [UUID: Song] {
        Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var filtered: [ImportRecord] {
        records.filter { r in
            (filter == .all || r.source == filter.rawValue)
            && (search.isEmpty
                || r.title.localizedCaseInsensitiveContains(search)
                || r.artist.localizedCaseInsensitiveContains(search))
        }
    }

    /// Secciones por día, de más reciente a más antiguo
    private var days: [(day: Date, items: [ImportRecord])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.importedAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.importedAt > $1.importedAt }) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView("No imports yet",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("Every song you import, from a file or from Songsterr, will show up here."))
                } else {
                    List {
                        Picker("Source", selection: $filter) {
                            ForEach(SourceFilter.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .listRowSeparator(.hidden)

                        ForEach(days, id: \.day) { group in
                            Section(dayTitle(group.day)) {
                                ForEach(group.items) { record in
                                    row(record)
                                }
                                .onDelete { offsets in
                                    offsets.map { group.items[$0] }.forEach { context.delete($0) }
                                    try? context.save()
                                }
                            }
                        }
                    }
                    .searchable(text: $search, prompt: "Search history")
                }
            }
            .sheetSize(width: 560, height: 520)
            .navigationTitle("History")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear History", systemImage: "trash", role: .destructive) { confirmClear = true }
                        .disabled(records.isEmpty)
                }
            }
            .confirmationDialog("Clear the whole history? Songs in your library are kept.",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { ImportHistory.clear(in: context) }
            }
        }
    }

    @ViewBuilder
    private func row(_ record: ImportRecord) -> some View {
        let song = record.songId.flatMap { songsById[$0] }
        Button {
            if let song {
                dismiss()
                onOpen(song)
            } else if let id = record.songsterrId {
                dismiss()
                onReimport(id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: record.isSongsterr ? "music.note.list" : "doc.richtext")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song?.title ?? record.title).font(.body.weight(.medium)).lineLimit(1)
                    HStack(spacing: 6) {
                        if !(song?.artist ?? record.artist).isEmpty {
                            Text(song?.artist ?? record.artist).lineLimit(1)
                            Text("·")
                        }
                        Text(record.isSongsterr ? "Songsterr" : (record.originalFileName ?? "File")).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(record.importedAt, format: .dateTime.hour().minute())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if song == nil {
                        Text(record.songsterrId != nil ? "Re-import" : "Deleted")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(song == nil && record.songsterrId == nil)
        .contextMenu {
            if let song {
                Button("Open", systemImage: "play.circle") { dismiss(); onOpen(song) }
            }
            if let id = record.songsterrId {
                Button("Import Again", systemImage: "arrow.down.circle") { dismiss(); onReimport(id) }
            }
            if let url = record.songsterrURL {
                Button("View on Songsterr", systemImage: "safari") { openURL(url) }
            }
            Divider()
            Button("Remove from History", systemImage: "trash", role: .destructive) {
                context.delete(record)
                try? context.save()
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

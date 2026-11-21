import SwiftUI
import SwiftData

/// Crea el engine y el reproductor UNA sola vez (un `@State var x = Clase()` se
/// re-evalúa en cada init de la vista y crearía WKWebViews de usar y tirar).
struct PlayerView: View {
    let song: Song
    /// Abrir directamente en modo edición (tabs recién creadas)
    var startEditing: Bool = false
    @State private var players: (engine: TabEngine, youtube: YouTubePlayer)?

    var body: some View {
        Group {
            if let players {
                PlayerContent(song: song, engine: players.engine, youtube: players.youtube, startEditing: startEditing)
            } else {
                ProgressView()
            }
        }
        .task {
            if players == nil { players = (TabEngine(), YouTubePlayer()) }
        }
    }
}

private struct PlayerContent: View {
    @Bindable var song: Song
    @Environment(\.modelContext) private var modelContext
    let engine: TabEngine
    let youtube: YouTubePlayer
    var startEditing = false

    @Environment(\.dismiss) private var dismiss
    /// Modo edición de la tablatura
    @State private var editing = false
    @State private var confirmEndEditing = false
    @State private var confirmLeave = false
    @State private var saving = false
    private var editorDirty: Bool { engine.editorState.dirty }

    @State private var mode: PlaybackMode = .synth
    @State private var speed: Double = 1.0
    /// Retraso del cursor respecto al reloj de audio, en ms (−1 = automático)
    @AppStorage("audioLatencyMs") private var latencyMs: Int = -1
    private static let latencyOptions = [-1, 0, 50, 100, 150, 200, 250, 300, 400]
    /// El vídeo arranca este tiempo antes del cursor para que ya suene al empezar
    private static let youtubePrerollMs: Double = 500
    @State private var looping = false
    @State private var metronome = false
    @State private var countIn = false
    @State private var horizontal = false
    @State private var scale: Double = 1.0
    @State private var showTracks = false
    @State private var showVideoLink = false
    @State private var syncEditing = false
    @State private var barSelecting = false
    @State private var showTuner = false
    /// Cambios de cuerda de esta sesión: temporales, se pierden al salir salvo que se pulse Keep
    @State private var sessionEdits: [StringEdit] = []
    @State private var videoCorner: Alignment = .bottomTrailing
    /// En iPhone el vídeo empieza pequeño para dejar sitio a la tab
    @State private var videoMinimized = Device.isPhone
    /// Vídeo oculto: sigue sonando, solo queda un botón para volver a mostrarlo
    @State private var videoHidden = false
    private let isPhone = Device.isPhone
    @State private var didSetup = false

    private static let synthSpeeds: [Double] = [0.25, 0.5, 0.6, 0.7, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5]
    private static let youtubeSpeeds: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private var speeds: [Double] { mode == .youtube ? Self.youtubeSpeeds : Self.synthSpeeds }

    var body: some View {
        ZStack(alignment: videoCorner) {
            TabWebView(engine: engine)
                .ignoresSafeArea(edges: [.bottom, .horizontal])

            if mode == .youtube, song.youtubeVideoId != nil {
                videoCard.padding(isPhone ? 8 : 12)
            }
        }
        .overlay(alignment: .top) {
            if engine.audioBlocked {
                Label("Tap the score to enable sound", systemImage: "speaker.wave.2.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.orange, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 12)
                    .allowsHitTesting(false) // el toque tiene que llegar a la web
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: engine.audioBlocked)
        .overlay(alignment: .top) {
            if let notice = engine.notice {
                Label(notice, systemImage: "info.circle.fill")
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, engine.audioBlocked ? 60 : 12)
                    .padding(.horizontal, 20)
                    .onTapGesture { engine.notice = nil }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(5))
                        if engine.notice == notice { engine.notice = nil }
                    }
            }
        }
        .animation(.snappy, value: engine.notice)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                PhoneScroll(enabled: isPhone) {
                VStack(spacing: 0) {
                if editing {
                    EditorPanel(engine: engine,
                                barSelection: engine.barSelection,
                                canRevert: song.isEdited,
                                onKeep: keepEditor,
                                onDiscard: discardEditor,
                                onRevert: revertToOriginal,
                                onDone: endEditing)
                    Divider()
                }
                if syncEditing {
                    SyncPanel(engine: engine, youtube: youtube) { syncEditing = false }
                    Divider()
                }
                if barSelecting {
                    BarLoopPanel(engine: engine, looping: $looping,
                                 unsavedEditCount: sessionEdits.count,
                                 savedEditCount: song.edits.count,
                                 onUndoEdit: undoLastEdit,
                                 onKeepEdits: keepEdits,
                                 onResetEdits: resetEdits) { barSelecting = false }
                    Divider()
                }
                }
                }
                transportBar
            }
            .background(.bar)
        }
        .navigationTitle(song.title)
        .inlineNavigationTitle()
        .toolbar { topToolbar }
        // Con cambios sin guardar, salir pregunta antes (en vez del botón «atrás» normal)
        .navigationBarBackButtonHidden(editorDirty)
        .toolbar {
            if editorDirty {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "chevron.backward") { confirmLeave = true }
                        .help("Close the song (you’ll be asked about unsaved changes)")
                }
            }
        }
        .confirmationDialog("You have unsaved changes to this tab.", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Keep Changes and Close") { keepEditor(then: { dismiss() }) }
            Button("Discard Changes and Close", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("You have unsaved changes to this tab.", isPresented: $confirmEndEditing, titleVisibility: .visible) {
            Button("Keep Changes") { keepEditor(then: { editing = false }) }
            Button("Discard Changes", role: .destructive) { discardEditor(); editing = false }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: editing) { _, on in
            engine.editor("setEnabled", [on])
            if on {
                syncEditing = false
                engine.pause()
                youtube.pause()
            }
        }
        .sheet(isPresented: $showTuner) { TunerView() }
        .sheet(isPresented: $showTracks) {
            TracksSheet(engine: engine).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showVideoLink) {
            VideoLinkSheet(song: song) { newId in
                if song.syncPoints.isEmpty { engine.clearSync() }
                if let newId {
                    youtube.load(videoId: newId)
                    if mode != .youtube { mode = .youtube }
                } else {
                    mode = .synth
                }
            }
        }
        .alert("Error", isPresented: .constant(engine.lastError != nil)) {
            Button("OK") { engine.lastError = nil }
        } message: {
            Text(engine.lastError ?? "")
        }
        .onChange(of: mode) { _, newMode in
            engine.setMode(newMode)
            if newMode == .youtube {
                if let id = song.youtubeVideoId { youtube.load(videoId: id) } else { showVideoLink = true }
            } else {
                youtube.unload()
                syncEditing = false
            }
            // Las velocidades de YouTube van en pasos de 0.25
            if newMode == .youtube, !Self.youtubeSpeeds.contains(speed) { setSpeed(1.0) }
        }
        .onChange(of: barSelecting) { _, on in
            engine.setBarSelectMode(on)
            if on { syncEditing = false }
        }
        .onChange(of: syncEditing) { _, on in if on { barSelecting = false; if editing { endEditing() } } }
        .onChange(of: engine.barSelection) { old, new in
            // Al elegir compases se activa la repetición sola
            if new != nil, old == nil { looping = true }
        }
        .onDisappear {
            engine.pause()
            youtube.pause()
        }
        .task { setup() }
    }

    // MARK: - Vídeo flotante

    private var videoCard: some View {
        let size = isPhone
            ? (videoMinimized ? CGSize(width: 144, height: 81) : CGSize(width: 288, height: 162))
            : (videoMinimized ? CGSize(width: 200, height: 112) : CGSize(width: 400, height: 225))
        return ZStack(alignment: .topLeading) {
            // Oculto sigue en pantalla (invisible) para que el vídeo no se pare
            YouTubePlayerView(player: youtube)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .opacity(videoHidden ? 0 : 1)
                .allowsHitTesting(!videoHidden)
            if videoHidden {
                Button { withAnimation(.snappy) { videoHidden = false } } label: {
                    Label("Video", systemImage: "play.rectangle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(isPhone ? .small : .regular)
                .help("Show the video")
                .frame(width: size.width, height: size.height, alignment: videoCorner)
            } else {
            HStack(spacing: 6) {
                Button { cycleCorner() } label: { Image(systemName: "arrow.up.and.down.and.arrow.left.and.right") }
                    .help("Move the video to the next corner")
                Button { videoMinimized.toggle() } label: {
                    Image(systemName: videoMinimized ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                }
                .help(videoMinimized ? "Enlarge the video" : "Shrink the video")
                Button { withAnimation(.snappy) { videoHidden = true } } label: { Image(systemName: "eye.slash") }
                    .help("Hide the video (it keeps playing)")
            }
            .font(.caption.bold())
            .buttonStyle(.bordered)
            .controlSize(isPhone ? .mini : .regular)
            .tint(.white)
            .padding(isPhone ? 4 : 6)
            }
            if let error = youtube.errorMessage {
                Text(error)
                    .font(.caption)
                    .padding(8)
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(width: size.width, height: size.height, alignment: .bottom)
            }
        }
        .shadow(radius: 8, y: 4)
        .animation(.snappy, value: videoMinimized)
    }

    private func cycleCorner() {
        let order: [Alignment] = [.bottomTrailing, .bottomLeading, .topLeading, .topTrailing]
        let i = order.firstIndex(of: videoCorner) ?? 0
        withAnimation(.snappy) { videoCorner = order[(i + 1) % order.count] }
    }

    // MARK: - Barra de transporte

    private var transportBar: some View {
        HStack(spacing: isPhone ? 10 : 16) {
            Button { engine.stop() } label: { Image(systemName: "backward.end.fill") }
                .keyboardShortcut(.home, modifiers: [])
                .help("Stop and go back to the start (Home)")

            Button { engine.playPause() } label: {
                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: isPhone ? 32 : 40))
            }
            .keyboardShortcut(syncEditing ? KeyEquivalent("p") : .space, modifiers: []) // en modo sync, espacio = marcar compás
            .disabled(!engine.isPlayerReady)
            .help(engine.isPlaying ? "Pause (Space)" : "Play (Space)")

            Text("\(format(engine.currentTime)) / \(format(engine.endTime))")
                .font((isPhone ? Font.caption : .callout).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()

            Text("\(isPhone ? "" : "Bar ")\(engine.currentBar + 1)\(engine.barCount > 0 ? " / \(engine.barCount)" : "")")
                .font((isPhone ? Font.caption : .callout).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .help("Current bar")

            Spacer()

            Menu {
                Picker("Speed", selection: Binding(get: { speed }, set: setSpeed)) {
                    ForEach(speeds, id: \.self) { Text("\(Int(($0 * 100).rounded())) %").tag($0) }
                }
                Section("Cursor delay (audio latency)") {
                    Picker("Cursor delay", selection: $latencyMs) {
                        ForEach(Self.latencyOptions, id: \.self) { value in
                            if value < 0 {
                                Text(mode == .synth ? "Auto (\(engine.autoLatencyMs) ms)" : "Auto (0 ms)").tag(value)
                            } else {
                                Text("\(value) ms").tag(value)
                            }
                        }
                    }
                }
            } label: {
                Label("\(Int((speed * 100).rounded())) %", systemImage: "speedometer").monospacedDigit()
                    .lineLimit(1)
                    .labelStyle(AdaptiveLabelStyle(iconOnly: isPhone && speed == 1))
            }
            .fixedSize()
            .help("Playback speed and cursor delay. Raise the delay if the cursor runs ahead of the sound (e.g. with Bluetooth headphones)")
            .onChange(of: latencyMs) { _, value in engine.setLatency(ms: value) }

            Toggle(isOn: $barSelecting) {
                Label(barLabel, systemImage: "rectangle.dashed")
                    .monospacedDigit()
                    .lineLimit(1)
                    .labelStyle(AdaptiveLabelStyle(iconOnly: isPhone && engine.barSelection == nil))
            }
            .fixedSize()
            .toggleStyle(.button)
            .help("Choose one or more bars to loop: tap the first and the last bar")

            Toggle(isOn: $looping) { Image(systemName: "repeat") }
                .toggleStyle(.button)
                .help(looping ? "Stop looping the selection" : "Loop the selection")
                .onChange(of: looping) { _, on in engine.setLooping(on) }

            if engine.hasSelection {
                Button { engine.clearSelection(); looping = false } label: { Image(systemName: "xmark.circle") }
                    .help("Clear selection")
            }

            if mode == .synth {
                Toggle(isOn: $metronome) { Image(systemName: "metronome") }
                    .toggleStyle(.button)
                    .help(metronome ? "Turn the metronome off" : "Turn the metronome on")
                    .onChange(of: metronome) { _, on in engine.setMetronome(on) }
                Toggle(isOn: $countIn) { Image(systemName: "timer") }
                    .toggleStyle(.button)
                    .help("Count in one bar before playing")
                    .onChange(of: countIn) { _, on in engine.setCountIn(on) }
            } else {
                Toggle(isOn: $syncEditing) {
                    Label("Sync", systemImage: "waveform.badge.plus")
                        .labelStyle(AdaptiveLabelStyle(iconOnly: isPhone))
                }
                    .toggleStyle(.button)
                    .help("Sync the tab with the video: mark each bar while it plays")
            }

            if song.youtubeVideoId != nil {
                Picker("Mode", selection: $mode) {
                    ForEach(PlaybackMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: isPhone ? 150 : 240)
                .help("Play with the built-in synth or with the YouTube video")
            }
        }
        .padding(.horizontal, isPhone ? 12 : 20)
        .padding(.vertical, isPhone ? 4 : 10)
    }

    private var barLabel: String {
        guard let r = engine.barSelection else { return "Bars" }
        return r.count == 1 ? "Bar \(r.lowerBound + 1)" : "\(r.lowerBound + 1)–\(r.upperBound + 1)"
    }

    // MARK: - Toolbar superior

    @ToolbarContentBuilder
    private var topToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(editing ? "Done Editing" : "Edit", systemImage: editing ? "checkmark.circle.fill" : "square.and.pencil") {
                if editing { endEditing() } else { editing = true }
            }
            .keyboardShortcut("e")
            .help(editing ? "Leave edit mode (⌘E)" : "Edit the tab: click a string and type a fret number (⌘E)")
            Button("Tuner", systemImage: "tuningfork") {
                // El micrófono oiría la propia reproducción: pausamos antes de afinar
                engine.pause()
                youtube.pause()
                showTuner = true
            }
            .keyboardShortcut("t")
            .help("Chromatic tuner (⌘T). Pauses playback")
            Button("Tracks", systemImage: "list.bullet") { showTracks = true }
                .disabled(engine.tracks.isEmpty)
                .help("Show, hide, mute or solo tracks")
            Button("Video", systemImage: song.youtubeVideoId == nil ? "play.rectangle" : "play.rectangle.fill") {
                showVideoLink = true
            }
            .help(song.youtubeVideoId == nil ? "Add a YouTube video" : "Change or remove the YouTube video")
            Button(horizontal ? "Page" : "Horizontal",
                   systemImage: horizontal ? "doc.plaintext" : "arrow.left.and.right.text.vertical") {
                horizontal.toggle()
                engine.setLayout(horizontal: horizontal)
            }
            .help(horizontal ? "Switch to page layout" : "Switch to a single horizontal line")
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom(-0.1) }
                .keyboardShortcut("-")
                .help("Zoom out (⌘−)")
            Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom(0.1) }
                .keyboardShortcut("=")
                .help("Zoom in (⌘+)")
        }
    }

    // MARK: - Lógica

    private func setup() {
        guard !didSetup else { return }
        didSetup = true
        song.lastOpenedAt = .now
        speed = song.lastSpeed

        engine.onScoreLoaded = { title, artist in
            if song.titleIsPlaceholder, !title.isEmpty {
                song.title = title
                song.artist = artist
                song.titleIsPlaceholder = false
                ImportHistory.updateTitle(for: song, in: modelContext)
            }
        }
        engine.onSyncPointsChanged = { points in song.syncPoints = points }
        engine.onSpace = {
            if syncEditing {
                if youtube.isPlaying { engine.markNextBar(atMs: youtube.estimatedTimeMs) } else { engine.play() }
            } else {
                engine.playPause()
            }
        }
        engine.onExternalPlay = {
            guard mode == .youtube else { return }
            // Pre-roll: el vídeo arranca medio segundo antes y el cursor espera al punto de inicio,
            // así el sonido ya ha arrancado cuando el cursor empieza a moverse.
            let start = youtube.currentTimeMs
            if !youtube.isPlaying, start > 0 {
                engine.holdExternal(untilMs: start)
                youtube.seek(toMs: max(0, start - Self.youtubePrerollMs))
            }
            youtube.play()
        }
        engine.onExternalPause = { youtube.pause() }
        engine.onExternalSeek = { ms in if mode == .youtube { youtube.seek(toMs: ms) } }
        engine.onExternalRate = { rate in youtube.setRate(rate) }
        // El vídeo solo manda en modo YouTube; en sintetizador se ignora
        youtube.onTime = { ms in if mode == .youtube { engine.externalTime(ms) } }
        youtube.onDuration = { ms in engine.externalDuration(ms) }
        youtube.onPlayingChanged = { playing in if mode == .youtube { engine.externalState(playing: playing) } }

        let initialMode: PlaybackMode = (song.youtubeVideoId != nil && !song.syncPoints.isEmpty) ? .youtube : .synth
        mode = initialMode
        if initialMode == .youtube, let id = song.youtubeVideoId { youtube.load(videoId: id) }
        engine.onEdited = { op in sessionEdits.append(op) }
        engine.loadSong(url: LocalSchemeHandler.songURL(song.fileName), syncPoints: song.syncPoints,
                        edits: song.edits, mode: initialMode)
        engine.setSpeed(speed)
        engine.setLatency(ms: latencyMs)
        if startEditing { editing = true }
    }

    private func undoLastEdit() {
        guard sessionEdits.popLast() != nil else { return }
        engine.reloadWithEdits(song.edits + sessionEdits)
    }

    /// Guarda los cambios de esta sesión para que se apliquen al volver a abrir la canción
    private func keepEdits() {
        song.edits += sessionEdits
        sessionEdits = []
        engine.notice = "String changes kept. They'll be there next time you open this song."
    }

    // MARK: - Editor

    private func endEditing() {
        if editorDirty { confirmEndEditing = true } else { editing = false }
    }

    /// Guarda la tab editada como copia (Guitar Pro 7); el archivo original se conserva
    private func keepEditor() { keepEditor(then: {}) }

    private func keepEditor(then done: @escaping () -> Void) {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let (data, syncPoints) = try await engine.exportEdited()
                try SongLibrary.saveEdited(song, data: data, into: modelContext)
                song.syncPoints = syncPoints
                sessionEdits = []
                engine.editor("saved")
                // Recargar desde el archivo guardado (así descartar/recargar parten de aquí)
                engine.loadSong(url: LocalSchemeHandler.songURL(song.fileName), syncPoints: song.syncPoints,
                                edits: [], mode: mode)
                engine.notice = song.isCreatedHere
                    ? "Saved."
                    : "Saved as an edited copy. Your original file is kept: use Revert to Original to go back."
                done()
            } catch {
                engine.lastError = error.localizedDescription
            }
        }
    }

    /// Descarta los cambios del editor: vuelve a cargar la última versión guardada
    private func discardEditor() {
        engine.reloadWithEdits(song.edits + sessionEdits)
        engine.notice = "Changes discarded."
    }

    private func revertToOriginal() {
        SongLibrary.revertToOriginal(song, in: modelContext)
        sessionEdits = []
        engine.loadSong(url: LocalSchemeHandler.songURL(song.fileName), syncPoints: song.syncPoints,
                        edits: [], mode: mode)
        engine.notice = "Back to the original tab."
    }

    /// Borra los cambios guardados y vuelve a la tab original
    private func resetEdits() {
        song.edits = []
        sessionEdits = []
        engine.reloadWithEdits([])
        engine.notice = "Back to the original tab."
    }

    private func setSpeed(_ value: Double) {
        speed = value
        song.lastSpeed = value
        engine.setSpeed(value)
    }

    private func zoom(_ delta: Double) {
        scale = min(2.0, max(0.5, scale + delta))
        engine.setScale(scale)
    }

    private func format(_ ms: Double) -> String {
        let total = Int(ms / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// En iPhone, los paneles anchos (editor, loops, sync) se desplazan en horizontal en vez de cortarse.
private struct PhoneScroll<Content: View>: View {
    let enabled: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if enabled {
            ScrollView(.horizontal, showsIndicators: false) { content }
        } else {
            content
        }
    }
}

/// Solo icono o icono + texto según el espacio disponible
private struct AdaptiveLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else {
            HStack(spacing: 6) { configuration.icon; configuration.title }
        }
    }
}

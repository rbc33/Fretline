import SwiftUI
import SwiftData

/// Crea el engine y el reproductor UNA sola vez (un `@State var x = Clase()` se
/// re-evalúa en cada init de la vista y crearía WKWebViews de usar y tirar).
struct PlayerView: View {
    let song: Song
    @State private var players: (engine: TabEngine, youtube: YouTubePlayer)?

    var body: some View {
        Group {
            if let players {
                PlayerContent(song: song, engine: players.engine, youtube: players.youtube)
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

    @State private var mode: PlaybackMode = .synth
    @State private var speed: Double = 1.0
    @State private var looping = false
    @State private var metronome = false
    @State private var countIn = false
    @State private var horizontal = false
    @State private var scale: Double = 1.0
    @State private var showTracks = false
    @State private var showVideoLink = false
    @State private var syncEditing = false
    @State private var videoCorner: Alignment = .topTrailing
    @State private var videoMinimized = false
    @State private var didSetup = false

    private static let synthSpeeds: [Double] = [0.25, 0.5, 0.6, 0.7, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5]
    private static let youtubeSpeeds: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private var speeds: [Double] { mode == .youtube ? Self.youtubeSpeeds : Self.synthSpeeds }

    var body: some View {
        ZStack(alignment: videoCorner) {
            TabWebView(engine: engine)
                .ignoresSafeArea(edges: [.bottom, .horizontal])

            if mode == .youtube, song.youtubeVideoId != nil {
                videoCard.padding(12)
            }
        }
        .overlay(alignment: .top) {
            if engine.audioBlocked {
                Label("Toca la partitura para activar el sonido", systemImage: "speaker.wave.2.fill")
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if syncEditing {
                    SyncPanel(engine: engine, youtube: youtube) { syncEditing = false }
                    Divider()
                }
                transportBar
            }
            .background(.bar)
        }
        .navigationTitle(song.title)
        .inlineNavigationTitle()
        .toolbar { topToolbar }
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
        .onDisappear {
            engine.pause()
            youtube.pause()
        }
        .task { setup() }
    }

    // MARK: - Vídeo flotante

    private var videoCard: some View {
        let size = videoMinimized ? CGSize(width: 200, height: 112) : CGSize(width: 400, height: 225)
        return ZStack(alignment: .topLeading) {
            YouTubePlayerView(player: youtube)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 6) {
                Button { cycleCorner() } label: { Image(systemName: "arrow.up.and.down.and.arrow.left.and.right") }
                Button { videoMinimized.toggle() } label: {
                    Image(systemName: videoMinimized ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                }
            }
            .font(.caption.bold())
            .buttonStyle(.bordered)
            .tint(.white)
            .padding(6)
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
        let order: [Alignment] = [.topTrailing, .bottomTrailing, .bottomLeading, .topLeading]
        let i = order.firstIndex(of: videoCorner) ?? 0
        withAnimation(.snappy) { videoCorner = order[(i + 1) % order.count] }
    }

    // MARK: - Barra de transporte

    private var transportBar: some View {
        HStack(spacing: 16) {
            Button { engine.stop() } label: { Image(systemName: "backward.end.fill") }
                .keyboardShortcut(.home, modifiers: [])

            Button { engine.playPause() } label: {
                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
            }
            .keyboardShortcut(syncEditing ? KeyEquivalent("p") : .space, modifiers: []) // en modo sync, espacio = marcar compás
            .disabled(!engine.isPlayerReady)

            Text("\(format(engine.currentTime)) / \(format(engine.endTime))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Text("Compás \(engine.currentBar + 1)\(engine.barCount > 0 ? " / \(engine.barCount)" : "")")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Menu {
                Picker("Velocidad", selection: Binding(get: { speed }, set: setSpeed)) {
                    ForEach(speeds, id: \.self) { Text("\(Int(($0 * 100).rounded())) %").tag($0) }
                }
            } label: {
                Label("\(Int((speed * 100).rounded())) %", systemImage: "speedometer").monospacedDigit()
            }

            Toggle(isOn: $looping) { Image(systemName: "repeat") }
                .toggleStyle(.button)
                .help("Repetir la selección (arrastra sobre la tab para seleccionar)")
                .onChange(of: looping) { _, on in engine.setLooping(on) }

            if engine.hasSelection {
                Button { engine.clearSelection() } label: { Image(systemName: "selection.pin.in.out") }
                    .help("Quitar selección")
            }

            if mode == .synth {
                Toggle(isOn: $metronome) { Image(systemName: "metronome") }
                    .toggleStyle(.button)
                    .onChange(of: metronome) { _, on in engine.setMetronome(on) }
                Toggle(isOn: $countIn) { Image(systemName: "timer") }
                    .toggleStyle(.button)
                    .help("Cuenta atrás antes de empezar")
                    .onChange(of: countIn) { _, on in engine.setCountIn(on) }
            } else {
                Toggle(isOn: $syncEditing) { Label("Sync", systemImage: "waveform.badge.plus") }
                    .toggleStyle(.button)
            }

            if song.youtubeVideoId != nil {
                Picker("Modo", selection: $mode) {
                    ForEach(PlaybackMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Toolbar superior

    @ToolbarContentBuilder
    private var topToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Pistas", systemImage: "list.bullet") { showTracks = true }
                .disabled(engine.tracks.isEmpty)
            Button("Vídeo", systemImage: song.youtubeVideoId == nil ? "play.rectangle" : "play.rectangle.fill") {
                showVideoLink = true
            }
            Button(horizontal ? "Página" : "Horizontal",
                   systemImage: horizontal ? "doc.plaintext" : "arrow.left.and.right.text.vertical") {
                horizontal.toggle()
                engine.setLayout(horizontal: horizontal)
            }
            Button("Alejar", systemImage: "minus.magnifyingglass") { zoom(-0.1) }
            Button("Acercar", systemImage: "plus.magnifyingglass") { zoom(0.1) }
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
        engine.onExternalPlay = { if mode == .youtube { youtube.play() } }
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
        engine.loadSong(url: LocalSchemeHandler.songURL(song.fileName), syncPoints: song.syncPoints, mode: initialMode)
        engine.setSpeed(speed)
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

import Foundation
import AVFoundation
import Observation
#if os(iOS)
import UIKit
#endif

/// Análisis del audio del micrófono. Vive solo en su propia cola serie
/// (nunca en el hilo principal); entrega los resultados por `onResult`.
final class PitchAnalyzer: @unchecked Sendable {
    struct Result: Sendable {
        /// Frecuencia estable (mediana de las últimas lecturas), nil en silencio
        let frequency: Double?
        /// Nivel de entrada 0…1
        let level: Float
    }

    let queue = DispatchQueue(label: "fretline.tuner", qos: .userInteractive)
    var onResult: (@Sendable (Result) -> Void)?

    private var window: [Float] = []
    private var recent: [Double] = []
    private var lastPitch = Date.distantPast

    private let windowSize = 8192
    private let silenceRMS: Float = 0.008
    /// Tiempo que se mantiene la última nota tras dejar de sonar
    private let holdTime: TimeInterval = 0.8

    /// Se llama desde el tap de audio: copia y encola, sin trabajo pesado en el hilo de audio.
    func enqueue(_ samples: [Float], sampleRate: Double) {
        queue.async { [weak self] in self?.process(samples, sampleRate: sampleRate) }
    }

    func reset() {
        queue.async { [weak self] in
            self?.window.removeAll()
            self?.recent.removeAll()
            self?.lastPitch = .distantPast
        }
    }

    private func process(_ samples: [Float], sampleRate: Double) {
        // Ventana deslizante de 8192 muestras (mejor precisión en notas graves)
        window.append(contentsOf: samples)
        if window.count > windowSize { window.removeFirst(window.count - windowSize) }
        guard window.count == windowSize else { return }

        let rms = PitchDetector.rms(window)
        let level = min(1, rms * 8)
        var stable: Double?

        if rms > silenceRMS,
           let f = PitchDetector.detect(window, sampleRate: sampleRate) {
            // Si salta más de un semitono respecto a lo anterior, empezamos de nuevo
            if let last = recent.last, abs(1200 * log2(f / last)) > 100 { recent.removeAll() }
            recent.append(f)
            if recent.count > 5 { recent.removeFirst() }
            lastPitch = Date()
            stable = recent.sorted()[recent.count / 2]
        } else if Date().timeIntervalSince(lastPitch) < holdTime, !recent.isEmpty {
            stable = recent.sorted()[recent.count / 2]
        } else {
            recent.removeAll()
        }
        onResult?(Result(frequency: stable, level: level))
    }
}

/// Afinador cromático: escucha el micrófono y publica la nota detectada.
@MainActor
@Observable
final class TunerEngine {
    enum Status: Equatable {
        case idle
        case listening
        case permissionDenied
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// Nota detectada; nil en silencio
    private(set) var note: TunedNote?
    /// Nivel de entrada 0…1
    private(set) var level: Float = 0

    /// Frecuencia de referencia del La4 (440 Hz por defecto)
    var a4: Double = 440 {
        didSet { if let f = note?.frequency { note = TunedNote(frequency: f, a4: a4) } }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let analyzer = PitchAnalyzer()

    init() {
        analyzer.onResult = { [weak self] result in
            Task { @MainActor in self?.apply(result) }
        }
    }

    private func apply(_ result: PitchAnalyzer.Result) {
        guard status == .listening else { return }
        level = result.level
        note = result.frequency.map { TunedNote(frequency: $0, a4: a4) }
    }

    // MARK: - Arranque y parada

    func start() async {
        guard status != .listening else { return }
        guard await Self.requestPermission() else {
            status = .permissionDenied
            return
        }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try session.setActive(true)
            #endif

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                status = .failed("No microphone input available.")
                return
            }
            let sampleRate = format.sampleRate
            let analyzer = self.analyzer
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                guard let channel = buffer.floatChannelData?[0] else { return }
                let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                analyzer.enqueue(samples, sampleRate: sampleRate)
            }
            engine.prepare()
            try engine.start()
            status = .listening
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        guard status == .listening else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        analyzer.reset()
        status = .idle
        note = nil
        level = 0
        #if os(iOS)
        // Volvemos a la sesión de solo reproducción que usa el resto de la app
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif
    }

    // MARK: - Permiso de micrófono

    static func requestPermission() async -> Bool {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
        #endif
    }

    /// Enlace a los ajustes de privacidad del micrófono
    static var settingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #endif
    }
}

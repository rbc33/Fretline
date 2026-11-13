import SwiftUI

/// Afinador cromático: nota, octava, desviación en cents con aguja y frecuencia.
struct TunerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var tuner = TunerEngine()
    @AppStorage("tunerA4") private var a4: Double = 440

    /// Afinación estándar (MIDI): E2 A2 D3 G3 B3 E4
    private static let standardStrings: [(name: String, midi: Int)] = [
        ("E", 40), ("A", 45), ("D", 50), ("G", 55), ("B", 59), ("E", 64),
    ]

    private var inTune: Bool {
        guard let n = tuner.note else { return false }
        return abs(n.cents) <= 5
    }

    private var tint: Color {
        guard let n = tuner.note else { return .secondary }
        switch abs(n.cents) {
        case ...5: return .green
        case ...15: return .yellow
        default: return .orange
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch tuner.status {
                case .permissionDenied:
                    permissionDenied
                case .failed(let message):
                    ContentUnavailableView("Tuner unavailable", systemImage: "mic.slash", description: Text(message))
                default:
                    tunerBody
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheetSize(width: 460, height: 560)
            .navigationTitle("Tuner")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .help("Close the tuner")
                }
            }
        }
        .task {
            tuner.a4 = a4
            await tuner.start()
        }
        .onDisappear { tuner.stop() }
        .onChange(of: a4) { _, value in tuner.a4 = value }
    }

    // MARK: - Afinador

    private var tunerBody: some View {
        VStack(spacing: 22) {
            // Nota
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(tuner.note?.name ?? "–")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(tuner.note == nil ? Color.secondary : tint)
                if let octave = tuner.note?.octave {
                    Text("\(octave)")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .contentTransition(.numericText())
            .animation(.snappy, value: tuner.note?.midi)
            .frame(height: 110)

            CentsGauge(cents: tuner.note?.cents, tint: tint)
                .frame(height: 150)
                .accessibilityLabel(accessibilityText)

            // Lectura
            VStack(spacing: 4) {
                if let n = tuner.note {
                    Text(inTune ? "In tune" : (n.cents < 0 ? "Flat \(Int(abs(n.cents).rounded())) cents" : "Sharp \(Int(n.cents.rounded())) cents"))
                        .font(.headline)
                        .foregroundStyle(tint)
                    Text(String(format: "%.1f Hz  ·  target %.1f Hz", n.frequency, n.targetFrequency))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(tuner.status == .listening ? "Play a note" : "Starting microphone…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(" ").font(.callout)
                }
            }

            // Cuerdas en afinación estándar
            HStack(spacing: 8) {
                ForEach(Array(Self.standardStrings.enumerated()), id: \.offset) { index, string in
                    let active = tuner.note?.midi == string.midi
                    Text(string.name)
                        .font(.headline.monospaced())
                        .frame(width: 40, height: 40)
                        .background(active ? tint.opacity(0.25) : Color.secondary.opacity(0.1), in: Circle())
                        .overlay(Circle().stroke(active ? tint : .clear, lineWidth: 2))
                        .help("String \(6 - index): \(string.name)\(string.midi / 12 - 1)")
                }
            }

            InputLevel(level: tuner.level)
                .frame(height: 4)
                .help("Microphone level")

            // Referencia
            HStack {
                Text("A4 =")
                Text("\(Int(a4)) Hz").monospacedDigit().bold()
                Stepper("Reference pitch", value: $a4, in: 415...466, step: 1)
                    .labelsHidden()
                    .help("Reference pitch for A4 (440 Hz is standard)")
                if a4 != 440 {
                    Button("Reset") { a4 = 440 }
                        .help("Back to 440 Hz")
                }
            }
            .font(.callout)
        }
    }

    private var permissionDenied: some View {
        ContentUnavailableView {
            Label("Microphone access needed", systemImage: "mic.slash")
        } description: {
            Text("Fretline needs the microphone to hear your instrument. Turn it on in Settings.")
        } actions: {
            if let url = TunerEngine.settingsURL {
                Button("Open Settings") { openURL(url) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var accessibilityText: String {
        guard let n = tuner.note else { return "No note detected" }
        return "\(n.name)\(n.octave), \(Int(n.cents.rounded())) cents"
    }
}

// MARK: - Aguja

/// Arco de −50 a +50 cents con zona verde de ±5 y una aguja.
private struct CentsGauge: View {
    let cents: Double?
    let tint: Color

    private let sweep: Double = 120 // grados totales del arco

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height - 6)
            let radius = min(geo.size.width / 2 - 12, geo.size.height - 18)
            ZStack {
                // Zona afinada (±5 cents)
                ArcShape(center: center, radius: radius, from: angle(-5), to: angle(5))
                    .stroke(Color.green.opacity(0.35), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                // Marcas cada 10 cents
                ForEach(-5...5, id: \.self) { i in
                    let a = angle(Double(i * 10))
                    let long = i == 0
                    Path { p in
                        p.move(to: point(center, radius - (long ? 22 : 12), a))
                        p.addLine(to: point(center, radius, a))
                    }
                    .stroke(Color.secondary.opacity(long ? 0.9 : 0.5), lineWidth: long ? 3 : 1.5)
                }
                Text("−50").font(.caption2).foregroundStyle(.secondary)
                    .position(point(center, radius + 14, angle(-50)))
                Text("+50").font(.caption2).foregroundStyle(.secondary)
                    .position(point(center, radius + 14, angle(50)))
                // Aguja
                Path { p in
                    p.move(to: center)
                    p.addLine(to: point(center, radius - 4, angle(clamped)))
                }
                .stroke(cents == nil ? Color.secondary.opacity(0.4) : tint,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .animation(.easeOut(duration: 0.12), value: clamped)
                Circle()
                    .fill(cents == nil ? Color.secondary.opacity(0.4) : tint)
                    .frame(width: 14, height: 14)
                    .position(center)
            }
        }
    }

    private var clamped: Double { min(50, max(-50, cents ?? 0)) }

    /// Ángulo en grados (0 = arriba) para un valor en cents
    private func angle(_ c: Double) -> Double { c / 50 * sweep / 2 }

    private func point(_ c: CGPoint, _ r: CGFloat, _ degrees: Double) -> CGPoint {
        let rad = (degrees - 90) * .pi / 180
        return CGPoint(x: c.x + r * cos(rad), y: c.y + r * sin(rad))
    }
}

private struct ArcShape: Shape {
    let center: CGPoint
    let radius: CGFloat
    let from: Double
    let to: Double

    func path(in rect: CGRect) -> Path {
        Path { p in
            p.addArc(center: center, radius: radius,
                     startAngle: .degrees(from - 90), endAngle: .degrees(to - 90), clockwise: false)
        }
    }
}

private struct InputLevel: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(Color.accentColor.opacity(0.7))
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(maxWidth: 220)
    }
}

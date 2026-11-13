import Foundation
import Accelerate

/// Detector de tono YIN (de Cheveigné & Kawahara, 2002).
/// Validado con tonos sintéticos de guitarra: ±1 cent de 41 Hz a 1,3 kHz.
enum PitchDetector {
    /// Devuelve la frecuencia fundamental en Hz, o nil si no hay un tono claro.
    /// - samples: ventana mono (8192 muestras va bien hasta ~30 Hz a 48 kHz)
    static func detect(_ samples: [Float],
                       sampleRate: Double,
                       minFrequency: Double = 30,
                       maxFrequency: Double = 1500,
                       threshold: Float = 0.12) -> Double? {
        let n = samples.count
        let w = n / 2
        let tauMin = max(2, Int(sampleRate / maxFrequency))
        let tauMax = min(w - 1, Int(sampleRate / minFrequency))
        guard tauMax > tauMin else { return nil }

        // 1. Función diferencia d(τ) = Σ (x[j] − x[j+τ])²
        var difference = [Float](repeating: 0, count: tauMax + 1)
        var scratch = [Float](repeating: 0, count: w)
        samples.withUnsafeBufferPointer { x in
            guard let base = x.baseAddress else { return }
            for tau in 1...tauMax {
                vDSP_vsub(base, 1, base + tau, 1, &scratch, 1, vDSP_Length(w))
                var sum: Float = 0
                vDSP_svesq(scratch, 1, &sum, vDSP_Length(w))
                difference[tau] = sum
            }
        }

        // 2. Diferencia normalizada por la media acumulada
        var cmnd = [Float](repeating: 1, count: tauMax + 1)
        var running: Float = 0
        for tau in 1...tauMax {
            running += difference[tau]
            cmnd[tau] = running > 0 ? difference[tau] * Float(tau) / running : 1
        }

        // 3. Primer mínimo bajo el umbral
        var tau = tauMin
        var found = -1
        while tau <= tauMax {
            if cmnd[tau] < threshold {
                while tau + 1 <= tauMax && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                found = tau
                break
            }
            tau += 1
        }
        guard found > 0 else { return nil }

        // 4. Interpolación parabólica para precisión por debajo de una muestra
        var period = Double(found)
        if found > 1 && found < tauMax {
            let s0 = cmnd[found - 1], s1 = cmnd[found], s2 = cmnd[found + 1]
            let denominator = s0 + s2 - 2 * s1
            if denominator != 0 { period += Double((s0 - s2) / (2 * denominator)) }
        }
        return sampleRate / period
    }

    static func rms(_ samples: [Float]) -> Float {
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }
}

/// Nota musical más cercana a una frecuencia.
struct TunedNote: Equatable {
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    let frequency: Double
    let midi: Int
    /// −50…+50 respecto a la nota más cercana
    let cents: Double
    let targetFrequency: Double

    init(frequency: Double, a4: Double) {
        let exact = 69 + 12 * log2(frequency / a4)
        let nearest = Int(exact.rounded())
        self.frequency = frequency
        self.midi = nearest
        self.cents = (exact - Double(nearest)) * 100
        self.targetFrequency = a4 * pow(2, Double(nearest - 69) / 12)
    }

    var name: String { Self.names[((midi % 12) + 12) % 12] }
    var octave: Int { midi / 12 - 1 }
}

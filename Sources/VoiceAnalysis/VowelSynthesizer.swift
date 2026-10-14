import Foundation

/// Source-filter vowel synthesizer used for tests and demos.
///
/// The source is a band-limited harmonic series whose amplitudes fall off by
/// `sourceTiltDbPerOctave`, so the source's own H1-H2 is known exactly:
/// `sourceTiltDbPerOctave * log2(2) = sourceTiltDbPerOctave` dB. The filter is a
/// cascade of second-order resonators, one per formant, each normalised to unit
/// gain at DC (the Klatt formulation).
public struct VowelSynthesizer: Sendable {
    public struct Formant: Sendable, Equatable {
        public var frequency: Double
        public var bandwidth: Double
        public init(_ frequency: Double, bandwidth: Double) {
            self.frequency = frequency
            self.bandwidth = bandwidth
        }
    }

    public var sampleRate: Double
    public var f0: Double
    public var formants: [Formant]
    public var sourceTiltDbPerOctave: Double
    public var amplitude: Float

    public init(sampleRate: Double = 16_000, f0: Double, formants: [Formant],
                sourceTiltDbPerOctave: Double = 12, amplitude: Float = 0.3) {
        self.sampleRate = sampleRate
        self.f0 = f0
        self.formants = formants
        self.sourceTiltDbPerOctave = sourceTiltDbPerOctave
        self.amplitude = amplitude
    }

    /// Peterson & Barney style averages. Bandwidths are typical adult values.
    public static func formants(_ f1: Double, _ f2: Double, _ f3: Double) -> [Formant] {
        [Formant(f1, bandwidth: 80), Formant(f2, bandwidth: 100), Formant(f3, bandwidth: 150)]
    }
    public static let masculineAh = formants(730, 1090, 2440)
    public static let masculineEe = formants(270, 2290, 3010)
    public static let feminineAh = formants(850, 1220, 2810)
    public static let feminineEe = formants(310, 2790, 3310)

    /// Renders `duration` seconds of a steady vowel.
    public func render(duration: Double) -> [Float] {
        let count = Int(duration * sampleRate)
        guard count > 0 else { return [] }

        // Harmonic source, band-limited to 90 % of Nyquist.
        let maxHarmonic = max(1, Int(0.45 * sampleRate / f0))
        var source = [Double](repeating: 0, count: count)
        let w0 = 2 * Double.pi * f0 / sampleRate
        for k in 1...maxHarmonic {
            let gain = pow(10, -sourceTiltDbPerOctave * log2(Double(k)) / 20)
            let wk = w0 * Double(k)
            for n in 0..<count {
                source[n] += gain * sin(wk * Double(n))
            }
        }

        // Resonator cascade.
        var y = source
        for formant in formants {
            let r = exp(-Double.pi * formant.bandwidth / sampleRate)
            let theta = 2 * Double.pi * formant.frequency / sampleRate
            let a1 = -2 * r * cos(theta)
            let a2 = r * r
            let b0 = 1 + a1 + a2
            var y1 = 0.0, y2 = 0.0
            for n in 0..<count {
                let out = b0 * y[n] - a1 * y1 - a2 * y2
                y2 = y1
                y1 = out
                y[n] = out
            }
        }

        let peak = y.map(abs).max() ?? 1
        let scale = peak > 0 ? Double(amplitude) / peak : 1
        return y.map { Float($0 * scale) }
    }
}

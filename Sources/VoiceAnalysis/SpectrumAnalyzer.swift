import Accelerate
import Foundation

/// Magnitude spectrum of one analysis frame.
public struct Spectrum: Sendable {
    public let sampleRate: Double
    /// Linear magnitudes for bins `0 ... fftLength / 2`.
    public let magnitudes: [Float]

    public var binWidth: Double { sampleRate / Double(2 * (magnitudes.count - 1)) }

    /// The strongest bin within `tolerance` (a fraction) of `frequency`, refined
    /// by parabolic interpolation on the decibel values.
    /// Returns the refined frequency and level in dB.
    public func peak(near frequency: Double, tolerance: Double = 0.25) -> (frequency: Double, level: Double)? {
        let low = max(1, Int((frequency * (1 - tolerance)) / binWidth))
        let high = min(magnitudes.count - 2, Int((frequency * (1 + tolerance)) / binWidth) + 1)
        guard low < high else { return nil }
        var best = low
        for k in low...high where magnitudes[k] > magnitudes[best] { best = k }
        func db(_ k: Int) -> Double { 20 * log10(Double(max(magnitudes[k], 1e-9))) }
        let alpha = db(best - 1), beta = db(best), gamma = db(best + 1)
        let denominator = alpha - 2 * beta + gamma
        var delta = 0.0
        if abs(denominator) > 1e-9 { delta = 0.5 * (alpha - gamma) / denominator }
        delta = max(-0.5, min(0.5, delta))
        let level = beta - 0.25 * (alpha - gamma) * delta
        return ((Double(best) + delta) * binWidth, level)
    }

    /// Power-weighted mean frequency between `lowHz` and `highHz`, a standard
    /// proxy for perceived brightness.
    public func centroid(from lowHz: Double, to highHz: Double) -> Double? {
        let low = max(0, Int(lowHz / binWidth))
        let high = min(magnitudes.count - 1, Int(highHz / binWidth))
        guard low < high else { return nil }
        var weighted = 0.0, total = 0.0
        for k in low...high {
            let power = Double(magnitudes[k]) * Double(magnitudes[k])
            weighted += power * Double(k) * binWidth
            total += power
        }
        guard total > 0 else { return nil }
        return weighted / total
    }

    /// Power in dB between `lowHz` and `highHz`.
    public func bandLevel(from lowHz: Double, to highHz: Double) -> Double? {
        let low = max(0, Int(lowHz / binWidth))
        let high = min(magnitudes.count - 1, Int(highHz / binWidth))
        guard low < high else { return nil }
        var total = 0.0
        for k in low...high { total += Double(magnitudes[k]) * Double(magnitudes[k]) }
        guard total > 0 else { return nil }
        return 10 * log10(total)
    }

    /// Alpha ratio (Frokjaer-Jensen & Prytz, 1976): level of the 1 to 5 kHz band
    /// minus the level of the 50 Hz to 1 kHz band, in dB. Higher is brighter.
    public func alphaRatio() -> Double? {
        guard let high = bandLevel(from: 1000, to: 5000),
              let low = bandLevel(from: 50, to: 1000) else { return nil }
        return high - low
    }
}

/// Real-input FFT wrapper. The vDSP setup is immutable once created and safe
/// to use from several threads, hence the unchecked Sendable conformance.
public final class SpectrumAnalyzer: @unchecked Sendable {
    public let sampleRate: Double
    public let fftLength: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let windowGain: Float

    public init(sampleRate: Double, fftLength: Int = 2048) {
        precondition(fftLength > 0 && fftLength & (fftLength - 1) == 0, "fftLength must be a power of two")
        self.sampleRate = sampleRate
        self.fftLength = fftLength
        self.log2n = vDSP_Length(log2(Double(fftLength)))
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = Window.hann(fftLength)
        self.windowGain = window.reduce(0, +)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    public var requiredSamples: Int { fftLength }

    /// Spectrum of the most recent `fftLength` samples of `x`, scaled so that a
    /// sine of amplitude A shows a peak of about A.
    public func spectrum(_ x: [Float]) -> Spectrum? {
        guard x.count >= fftLength else { return nil }
        let frame = Signal.multiply(Array(x[(x.count - fftLength)...]), window)
        let half = fftLength / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half + 1)

        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                frame.withUnsafeBytes { bytes in
                    vDSP_ctoz(bytes.baseAddress!.assumingMemoryBound(to: DSPComplex.self), 2,
                              &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // Packed format: real[0] is DC, imag[0] is the Nyquist bin.
                let nyquist = i[0]
                i[0] = 0
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                magnitudes[half] = abs(nyquist)
            }
        }
        // zrip output is scaled by 2; divide by the window's coherent gain.
        var scale = 1 / (2 * windowGain) * 2   // amplitude of a sine, not its half-spectrum share
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half + 1))
        return Spectrum(sampleRate: sampleRate, magnitudes: magnitudes)
    }
}

/// Harmonic amplitude measures of the voice source.
public enum HarmonicMeasures {
    /// Level difference between the first and second harmonic in dB, measured
    /// straight off the spectrum. Positive means a steeper spectral slope
    /// (lighter, breathier); negative means pressed or heavy.
    public static func h1h2(spectrum: Spectrum, f0: Double) -> Double? {
        guard let h1 = spectrum.peak(near: f0, tolerance: 0.2),
              let h2 = spectrum.peak(near: 2 * f0, tolerance: 0.15) else { return nil }
        return h1.level - h2.level
    }

    /// Gain in dB that the given formants add at `frequency`, relative to DC,
    /// after Iseli & Alwan (2004). Subtracting it from a measured harmonic
    /// level recovers the source level.
    public static func formantGain(at frequency: Double, formants: [Formant], sampleRate: Double) -> Double {
        var total = 0.0
        let omega = 2 * Double.pi * frequency / sampleRate
        for formant in formants {
            let r = exp(-Double.pi * formant.bandwidth / sampleRate)
            let omegaI = 2 * Double.pi * formant.frequency / sampleRate
            let a = r * r + 1 - 2 * r * cos(omegaI + omega)
            let b = r * r + 1 - 2 * r * cos(omegaI - omega)
            let dc = r * r + 1 - 2 * r * cos(omegaI)
            total += -10 * log10(a * b) + 20 * log10(dc)
        }
        return total
    }

    /// H1*-H2*: `h1h2` with the influence of the first two formants removed.
    public static func correctedH1H2(spectrum: Spectrum, f0: Double, formants: [Formant]) -> Double? {
        guard let h1 = spectrum.peak(near: f0, tolerance: 0.2),
              let h2 = spectrum.peak(near: 2 * f0, tolerance: 0.15) else { return nil }
        let used = Array(formants.prefix(2))
        let h1Star = h1.level - formantGain(at: h1.frequency, formants: used, sampleRate: spectrum.sampleRate)
        let h2Star = h2.level - formantGain(at: h2.frequency, formants: used, sampleRate: spectrum.sampleRate)
        return h1Star - h2Star
    }
}

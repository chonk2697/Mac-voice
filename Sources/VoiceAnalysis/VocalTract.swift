import Foundation

/// Vocal tract size estimated from formant frequencies.
public enum VocalTract {
    /// Speed of sound in warm, humid air, in cm/s.
    public static let speedOfSound = 35_000.0

    /// Estimated vocal tract length in centimetres.
    ///
    /// A uniform tube closed at the glottis has resonances at
    /// `F_i = (2i - 1) c / 4L`. The formants are regressed on `(2i - 1)` through
    /// the origin, which is the intrinsic, single-recording estimate described by
    /// Anikin, Barreda and Reby (2023). It is vowel-dependent frame to frame, so
    /// callers should smooth it over speech.
    public static func length(formants: [Double]) -> Double? {
        guard formants.count >= 2 else { return nil }
        var numerator = 0.0, denominator = 0.0
        for (i, f) in formants.enumerated() {
            let n = Double(2 * i + 1)
            numerator += f * n
            denominator += n * n
        }
        let spacing = numerator / denominator
        guard spacing > 0 else { return nil }
        return speedOfSound / (4 * spacing)
    }
}

/// Anchors that map raw measurements onto 0 to 100 gauges. Values are typical
/// adult figures and deliberately adjustable; they are starting points, not
/// clinical norms.
public struct Calibration: Sendable, Codable, Equatable {
    /// Vocal tract length (cm) shown as 0 (dark, large) on the resonance gauge.
    public var darkVocalTractLength = 18.5
    /// Vocal tract length (cm) shown as 100 (bright, small).
    public var brightVocalTractLength = 13.5
    /// H1*-H2* (dB) shown as 0 (light) on the weight gauge.
    public var lightH1H2 = 12.0
    /// H1*-H2* (dB) shown as 100 (heavy).
    public var heavyH1H2 = -3.0

    public init() {}

    /// Linear map of `value` from `zero` to `hundred`, clamped to 0...100.
    public static func gauge(_ value: Double, zero: Double, hundred: Double) -> Double {
        guard hundred != zero else { return 50 }
        let t = (value - zero) / (hundred - zero)
        return max(0, min(100, t * 100))
    }

    public func resonanceGauge(vocalTractLength: Double) -> Double {
        Calibration.gauge(vocalTractLength, zero: darkVocalTractLength, hundred: brightVocalTractLength)
    }

    public func weightGauge(h1h2: Double) -> Double {
        Calibration.gauge(h1h2, zero: lightH1H2, hundred: heavyH1H2)
    }
}

import Accelerate
import Foundation

/// A pitch estimate for one analysis frame.
public struct PitchEstimate: Sendable, Equatable {
    /// Fundamental frequency in hertz.
    public var frequency: Double
    /// Periodicity from 0 to 1, where 1 is a perfectly periodic signal.
    public var clarity: Double

    public init(frequency: Double, clarity: Double) {
        self.frequency = frequency
        self.clarity = clarity
    }
}

/// Fundamental frequency estimation with the YIN algorithm
/// (de Cheveigné & Kawahara, 2002), steps 1 to 5.
///
/// The detector is a value type with no state, so one instance can be shared
/// across threads. It needs `requiredSamples` samples per call.
public struct YINPitchDetector: Sendable {
    public let sampleRate: Double
    public let minFrequency: Double
    public let maxFrequency: Double
    /// Length of the integration window in samples.
    public let windowLength: Int
    /// First dip below this value in the normalised difference is taken as the period.
    public let threshold: Double
    /// Frames whose best dip is above this value are reported as unvoiced.
    public let voicingThreshold: Double

    public let tauMin: Int
    public let tauMax: Int

    public init(sampleRate: Double,
                minFrequency: Double = 60,
                maxFrequency: Double = 600,
                windowLength: Int = 1024,
                threshold: Double = 0.15,
                voicingThreshold: Double = 0.4) {
        precondition(minFrequency > 0 && maxFrequency > minFrequency)
        self.sampleRate = sampleRate
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.windowLength = windowLength
        self.threshold = threshold
        self.voicingThreshold = voicingThreshold
        self.tauMax = Int((sampleRate / minFrequency).rounded(.up))
        self.tauMin = max(2, Int((sampleRate / maxFrequency).rounded(.down)))
    }

    /// Number of samples `estimate` needs: the window plus the longest lag.
    public var requiredSamples: Int { windowLength + tauMax }

    /// Estimates the pitch of the most recent `requiredSamples` samples of `x`.
    /// Returns nil when the frame is not periodic enough to be voiced.
    public func estimate(_ x: [Float]) -> PitchEstimate? {
        guard x.count >= requiredSamples else { return nil }
        let start = x.count - requiredSamples
        let w = windowLength

        // Step 2: difference function d(tau) = sum_j (x[j] - x[j + tau])^2.
        var d = [Float](repeating: 0, count: tauMax + 1)
        x.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress! + start
            var diff = [Float](repeating: 0, count: w)
            for tau in 1...tauMax {
                // C = A - B with A = x[j], B = x[j + tau].
                vDSP_vsub(base + tau, 1, base, 1, &diff, 1, vDSP_Length(w))
                var sum: Float = 0
                vDSP_svesq(diff, 1, &sum, vDSP_Length(w))
                d[tau] = sum
            }
        }

        // Step 3: cumulative mean normalised difference.
        var cmnd = [Float](repeating: 1, count: tauMax + 1)
        var running: Float = 0
        for tau in 1...tauMax {
            running += d[tau]
            cmnd[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
        }

        // Step 4: absolute threshold, then follow the dip to its bottom.
        var tauEstimate = -1
        var tau = tauMin
        while tau <= tauMax {
            if cmnd[tau] < Float(threshold) {
                while tau + 1 <= tauMax, cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                tauEstimate = tau
                break
            }
            tau += 1
        }
        if tauEstimate < 0 {
            var best = tauMin
            for t in tauMin...tauMax where cmnd[t] < cmnd[best] { best = t }
            guard cmnd[best] < Float(voicingThreshold) else { return nil }
            tauEstimate = best
        }

        // Step 5: parabolic interpolation around the chosen lag.
        var period = Double(tauEstimate)
        if tauEstimate > 1, tauEstimate < tauMax {
            let s0 = Double(cmnd[tauEstimate - 1])
            let s1 = Double(cmnd[tauEstimate])
            let s2 = Double(cmnd[tauEstimate + 1])
            let denominator = 2 * (s0 - 2 * s1 + s2)
            if abs(denominator) > 1e-12 {
                let offset = (s0 - s2) / denominator
                if abs(offset) < 1 { period += offset }
            }
        }

        let clarity = max(0, min(1, 1 - Double(cmnd[tauEstimate])))
        return PitchEstimate(frequency: sampleRate / period, clarity: clarity)
    }
}

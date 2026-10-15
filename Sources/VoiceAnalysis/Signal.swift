import Accelerate
import Foundation

/// Window functions shared by the analyzers.
public enum Window {
    public static func hann(_ count: Int) -> [Float] {
        vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                    count: count, isHalfWindow: false)
    }

    public static func hamming(_ count: Int) -> [Float] {
        vDSP.window(ofType: Float.self, usingSequence: .hamming,
                    count: count, isHalfWindow: false)
    }

    /// Gaussian window with standard deviation `sigmaFraction` of the length.
    /// Praat's LPC window is a Gaussian with `sigmaFraction` 1 / sqrt(24)
    /// (its `exp(-12 x^2)` shape over -0.5...0.5), tails trimmed to zero.
    public static func gaussian(_ count: Int, sigmaFraction: Double = 1.0 / 6) -> [Float] {
        let mid = Double(count - 1) / 2
        let sigma = Double(count) * sigmaFraction
        let edge = exp(-0.5 * (mid / sigma) * (mid / sigma))
        return (0..<count).map { i in
            let d = (Double(i) - mid) / sigma
            return Float((exp(-0.5 * d * d) - edge) / (1 - edge))
        }
    }

    /// Praat's window shape: the Gaussian above with `sigmaFraction` 1 / sqrt(24).
    public static let praatSigmaFraction = 1.0 / 24.0.squareRoot()
}

/// Small signal helpers.
public enum Signal {
    /// Root-mean-square level of a block of samples.
    public static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var r: Float = 0
        vDSP_rmsqv(x, 1, &r, vDSP_Length(x.count))
        return r
    }

    /// Level in decibels relative to full scale, floored at -120 dB.
    public static func decibels(_ rms: Float) -> Float {
        20 * log10(max(rms, 1e-6))
    }

    /// First-order pre-emphasis `y[n] = x[n] - a * x[n-1]`, with `a` chosen so
    /// that frequencies above `fromHz` are boosted by about 6 dB per octave.
    public static func preEmphasis(_ x: [Float], sampleRate: Double, fromHz: Double = 50) -> [Float] {
        guard x.count > 1 else { return x }
        let a = Float(exp(-2 * .pi * fromHz / sampleRate))
        var y = x
        for i in stride(from: x.count - 1, through: 1, by: -1) {
            y[i] = x[i] - a * x[i - 1]
        }
        return y
    }

    /// Element-wise product, used to apply a window.
    public static func multiply(_ x: [Float], _ w: [Float]) -> [Float] {
        precondition(x.count == w.count)
        return vDSP.multiply(x, w)
    }
}

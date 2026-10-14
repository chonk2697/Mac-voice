import Foundation

/// Rational sample-rate conversion by `up / down` with a Kaiser-windowed sinc
/// low-pass filter. Stateless: `resample` returns only the outputs for which
/// the whole filter lies inside the input, so callers hand it a window with
/// some margin and keep the tail.
public struct Resampler: Sendable {
    public let up: Int
    public let down: Int
    public let taps: [Float]

    /// - Parameters:
    ///   - up: interpolation factor L.
    ///   - down: decimation factor M.
    ///   - tapCount: filter length at the upsampled rate (odd keeps it symmetric).
    ///   - beta: Kaiser window shape; 8 gives roughly 80 dB of stopband attenuation.
    ///   - cutoff: low-pass cutoff as a fraction of the upsampled Nyquist frequency.
    public init(up: Int, down: Int, tapCount: Int = 191, beta: Double = 8,
                cutoff: Double? = nil) {
        precondition(up > 0 && down > 0 && tapCount > 2)
        self.up = up
        self.down = down
        let fc = (cutoff ?? 0.94 / Double(max(up, down))) * 0.5   // cycles per upsampled sample
        let mid = Double(tapCount - 1) / 2
        let i0Beta = Resampler.besselI0(beta)
        var h = [Float](repeating: 0, count: tapCount)
        for n in 0..<tapCount {
            let t = Double(n) - mid
            let sinc = t == 0 ? 2 * fc : sin(2 * .pi * fc * t) / (.pi * t)
            let x = 2 * t / Double(tapCount - 1)
            let window = Resampler.besselI0(beta * sqrt(max(0, 1 - x * x))) / i0Beta
            h[n] = Float(sinc * window * Double(up))
        }
        self.taps = h
    }

    /// Number of input samples needed to produce `outputs` valid output samples.
    public func inputCount(forOutputs outputs: Int) -> Int {
        ((outputs - 1) * down + taps.count) / up + 2
    }

    /// Number of valid outputs for `inputs` input samples.
    public func outputCount(forInputs inputs: Int) -> Int {
        max(0, (inputs * up - taps.count) / down + 1)
    }

    /// Resamples `x`, returning only fully-valid outputs. The result is delayed
    /// by `(taps - 1) / 2` upsampled samples relative to the input.
    public func resample(_ x: [Float]) -> [Float] {
        let count = outputCount(forInputs: x.count)
        guard count > 0 else { return [] }
        var y = [Float](repeating: 0, count: count)
        let tapCount = taps.count
        x.withUnsafeBufferPointer { input in
            taps.withUnsafeBufferPointer { h in
                for n in 0..<count {
                    let t = n * down + tapCount - 1   // position on the upsampled grid
                    // Only upsampled positions that are multiples of `up` hold input samples.
                    var k = t % up
                    var sum: Float = 0
                    while k < tapCount {
                        sum += h[k] * input[(t - k) / up]
                        k += up
                    }
                    y[n] = sum
                }
            }
        }
        return y
    }

    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let half = x / 2
        var k = 1.0
        while term > 1e-12 * sum {
            term *= (half / k) * (half / k)
            sum += term
            k += 1
        }
        return sum
    }
}

import Foundation

/// Second-order IIR section in transposed direct form II.
struct Biquad: Sendable {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1 = 0.0, z2 = 0.0

    /// Butterworth-style high-pass section (RBJ cookbook) with the given Q.
    static func highPass(sampleRate: Double, cutoff: Double, q: Double) -> Biquad {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw0 = cos(w0)
        let a0 = 1 + alpha
        return Biquad(b0: (1 + cosw0) / 2 / a0,
                      b1: -(1 + cosw0) / a0,
                      b2: (1 + cosw0) / 2 / a0,
                      a1: -2 * cosw0 / a0,
                      a2: (1 - alpha) / a0)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Fourth-order Butterworth high-pass, used to remove DC, rumble and mains hum
/// before analysis. Keeps its state between calls so it can run on a stream.
public struct HighPassFilter: Sendable {
    public let sampleRate: Double
    public let cutoff: Double
    private var sections: [Biquad]

    public init(sampleRate: Double, cutoff: Double) {
        self.sampleRate = sampleRate
        self.cutoff = cutoff
        // Q values of the two sections of a 4th-order Butterworth response.
        sections = [Biquad.highPass(sampleRate: sampleRate, cutoff: cutoff, q: 0.5412),
                    Biquad.highPass(sampleRate: sampleRate, cutoff: cutoff, q: 1.3066)]
    }

    public mutating func process(_ x: [Float]) -> [Float] {
        var y = x
        for i in 0..<y.count {
            var sample = Double(y[i])
            for s in 0..<sections.count { sample = sections[s].process(sample) }
            y[i] = Float(sample)
        }
        return y
    }
}

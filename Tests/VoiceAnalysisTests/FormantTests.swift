import Foundation
import Testing
@testable import VoiceAnalysis

@Suite("Formant estimation")
struct FormantTests {
    let sampleRate = 16_000.0

    @Test("Burg LPC recovers a known two-pole filter")
    func burgRecoversResonator() throws {
        // Drive a single resonator with white noise and check the pole it finds.
        let f = 1000.0, bw = 100.0
        let r = exp(-Double.pi * bw / sampleRate)
        let a1 = -2 * r * cos(2 * Double.pi * f / sampleRate)
        let a2 = r * r
        var generator = SystemRandomNumberGenerator()
        var y = [Double](repeating: 0, count: 4000)
        var y1 = 0.0, y2 = 0.0
        for n in 0..<y.count {
            let out = Double.random(in: -1...1, using: &generator) - a1 * y1 - a2 * y2
            y2 = y1; y1 = out; y[n] = out
        }
        let (a, _) = try #require(LinearPrediction.burg(y, order: 2))
        #expect(abs(a[1] - a1) < 0.02)
        #expect(abs(a[2] - a2) < 0.02)
    }

    @Test("root finder solves (z - 0.5)(z^2 + 0.25) exactly")
    func rootsOfKnownPolynomial() {
        // z^3 - 0.5 z^2 + 0.25 z - 0.125
        let roots = Polynomial.roots(monic: [-0.5, 0.25, -0.125])
        let expected = [Complex(0.5, 0), Complex(0, 0.5), Complex(0, -0.5)]
        for e in expected {
            #expect(roots.contains { ($0 - e).magnitude < 1e-9 })
        }
    }

    static let vowels: [(String, [VowelSynthesizer.Formant])] = [
        ("masculine ah", VowelSynthesizer.masculineAh),
        ("masculine ee", VowelSynthesizer.masculineEe),
        ("feminine ah", VowelSynthesizer.feminineAh),
        ("feminine ee", VowelSynthesizer.feminineEe),
    ]

    @Test("finds F1 to F3 of synthesized vowels", arguments: [100.0, 140, 200, 250], vowels)
    func vowelFormants(f0: Double, vowel: (String, [VowelSynthesizer.Formant])) throws {
        let (name, expected) = vowel
        let estimator = FormantEstimator(sampleRate: sampleRate)
        let synth = VowelSynthesizer(sampleRate: sampleRate, f0: f0, formants: expected)
        let samples = synth.render(duration: 0.1)
        let found = estimator.estimate(samples)
        let summary = found.map { String(format: "%.0f/%.0f", $0.frequency, $0.bandwidth) }
        #expect(found.count == 3, "\(name) at \(f0) Hz: found \(summary)")
        for (index, (f, e)) in zip(found, expected).enumerated() {
            // F1 cannot be resolved better than the harmonic spacing allows,
            // so its tolerance grows with f0. Praat has the same limit.
            var tolerance = max(0.08 * e.frequency, 60)
            if index == 0 { tolerance = max(tolerance, f0 / 2) }
            #expect(abs(f.frequency - e.frequency) < tolerance,
                    "\(name) at \(f0) Hz: expected \(e.frequency) Hz, got \(f.frequency) Hz (\(summary))")
        }
    }

    @Test("resampler preserves a tone below the new Nyquist frequency")
    func resamplerTone() throws {
        let resampler = Resampler(up: 2, down: 3)
        let f = 1000.0
        let input = (0..<2000).map { Float(sin(2 * Double.pi * f * Double($0) / sampleRate)) }
        let output = resampler.resample(input)
        #expect(output.count == resampler.outputCount(forInputs: input.count))
        let detector = YINPitchDetector(sampleRate: sampleRate * 2 / 3, maxFrequency: 2000)
        let estimate = try #require(detector.estimate(output))
        #expect(abs(estimate.frequency - f) / f < 0.01)
        #expect(abs(Signal.rms(output) - Signal.rms(input)) < 0.02)
    }

    @Test("silence yields no formants")
    func silence() {
        let estimator = FormantEstimator(sampleRate: sampleRate)
        #expect(estimator.estimate([Float](repeating: 0, count: 800)).isEmpty)
    }
}

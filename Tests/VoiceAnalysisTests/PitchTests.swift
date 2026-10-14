import Foundation
import Testing
@testable import VoiceAnalysis

@Suite("YIN pitch detection")
struct PitchTests {
    let sampleRate = 16_000.0

    @Test("tracks a pure tone within 1 %", arguments: [70.0, 110, 150, 200, 260, 400, 550])
    func pureTone(_ frequency: Double) throws {
        let detector = YINPitchDetector(sampleRate: sampleRate)
        let samples = (0..<detector.requiredSamples).map {
            Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / sampleRate))
        }
        let estimate = try #require(detector.estimate(samples))
        #expect(abs(estimate.frequency - frequency) / frequency < 0.01)
        #expect(estimate.clarity > 0.9)
    }

    @Test("tracks a synthesized vowel within 1 %", arguments: [
        (110.0, VowelSynthesizer.masculineAh),
        (125.0, VowelSynthesizer.masculineEe),
        (190.0, VowelSynthesizer.feminineAh),
        (220.0, VowelSynthesizer.feminineEe),
    ])
    func vowel(_ f0: Double, _ formants: [VowelSynthesizer.Formant]) throws {
        let detector = YINPitchDetector(sampleRate: sampleRate)
        let synth = VowelSynthesizer(sampleRate: sampleRate, f0: f0, formants: formants)
        let samples = synth.render(duration: 0.2)
        let estimate = try #require(detector.estimate(samples))
        #expect(abs(estimate.frequency - f0) / f0 < 0.01)
        #expect(estimate.clarity > 0.8)
    }

    @Test("silence is unvoiced")
    func silence() {
        let detector = YINPitchDetector(sampleRate: sampleRate)
        let samples = [Float](repeating: 0, count: detector.requiredSamples)
        #expect(detector.estimate(samples) == nil)
    }

    @Test("white noise is unvoiced")
    func noise() {
        let detector = YINPitchDetector(sampleRate: sampleRate)
        var generator = SystemRandomNumberGenerator()
        let samples = (0..<detector.requiredSamples).map { _ in
            Float.random(in: -0.5...0.5, using: &generator)
        }
        #expect(detector.estimate(samples) == nil)
    }

    @Test("too few samples yields nil rather than crashing")
    func shortInput() {
        let detector = YINPitchDetector(sampleRate: sampleRate)
        #expect(detector.estimate([Float](repeating: 0.1, count: 100)) == nil)
    }
}

import Foundation
import Testing
@testable import VoiceAnalysis

@Suite("Noise rejection")
struct NoiseTests {
    let sampleRate = 16_000.0

    private func tone(_ f: Double, amplitude: Double, seconds: Double) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { Float(amplitude * sin(2 * Double.pi * f * Double($0) / sampleRate)) }
    }

    private func frames(_ audio: [Float]) -> [VoiceFrame] {
        let analyzer = VoiceAnalyzer()
        var out: [VoiceFrame] = []
        for start in stride(from: 0, to: audio.count, by: 512) {
            out += analyzer.process(Array(audio[start..<min(start + 512, audio.count)]))
        }
        return out.filter { $0.time > 0.2 }
    }

    @Test("high-pass removes mains hum and passes speech frequencies")
    func highPass() {
        var filter = HighPassFilter(sampleRate: sampleRate, cutoff: 75)
        let hum = filter.process(tone(60, amplitude: 0.5, seconds: 1))
        let humDrop = Signal.decibels(Signal.rms(Array(hum.suffix(8000)))) - Signal.decibels(0.5 / sqrt(2))
        #expect(humDrop < -7, "hum attenuated by \(humDrop) dB")
        var filter2 = HighPassFilter(sampleRate: sampleRate, cutoff: 75)
        let speech = filter2.process(tone(1000, amplitude: 0.5, seconds: 1))
        let speechDrop = Signal.decibels(Signal.rms(Array(speech.suffix(8000)))) - Signal.decibels(0.5 / sqrt(2))
        #expect(abs(speechDrop) < 0.5)
    }

    @Test("mains hum alone is not voiced", arguments: [50.0, 60.0])
    func humAlone(_ f: Double) {
        let hum = tone(f, amplitude: 0.05, seconds: 1)   // about -29 dBFS, well above the gate
        let result = frames(hum)
        #expect(!result.isEmpty)
        #expect(result.allSatisfy { !$0.isVoiced }, "voiced frames: \(result.filter(\.isVoiced).count)")
    }

    @Test("hum under a vowel does not steal the pitch")
    func humUnderVowel() throws {
        let synth = VowelSynthesizer(f0: 190, formants: VowelSynthesizer.feminineAh, amplitude: 0.2)
        let vowel = synth.render(duration: 1)
        let hum = tone(60, amplitude: 0.05, seconds: 1)
        let mixed = zip(vowel, hum).map(+)
        let voiced = frames(mixed).filter(\.isVoiced)
        #expect(voiced.count > 30)
        for frame in voiced {
            let pitch = try #require(frame.pitch)
            #expect(abs(pitch - 190) / 190 < 0.01)
        }
    }

    @Test("quiet broadband noise is not voiced")
    func noiseFloor() {
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<16_000).map { _ in Float.random(in: -0.01...0.01, using: &generator) }
        #expect(frames(noise).allSatisfy { !$0.isVoiced })
    }
}

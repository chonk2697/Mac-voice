import Foundation
import Testing
@testable import VoiceAnalysis

@Suite("Spectral features")
struct SpectralTests {
    let sampleRate = 16_000.0

    @Test("peak picking locates a tone between bins")
    func peakOfTone() throws {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate)
        let f = 1003.7
        let x = (0..<analyzer.requiredSamples).map {
            Float(0.5 * sin(2 * Double.pi * f * Double($0) / sampleRate))
        }
        let spectrum = try #require(analyzer.spectrum(x))
        let peak = try #require(spectrum.peak(near: 1000))
        #expect(abs(peak.frequency - f) < 2)
        #expect(abs(peak.level - 20 * log10(0.5)) < 0.5)
    }

    @Test("centroid of a tone is the tone")
    func centroidOfTone() throws {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate)
        let x = (0..<analyzer.requiredSamples).map {
            Float(sin(2 * Double.pi * 1000 * Double($0) / sampleRate))
        }
        let spectrum = try #require(analyzer.spectrum(x))
        let centroid = try #require(spectrum.centroid(from: 100, to: 8000))
        #expect(abs(centroid - 1000) < 20)
    }

    @Test("a brighter source raises the centroid and the alpha ratio")
    func brightnessTracksTilt() throws {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate)
        func measures(tilt: Double) throws -> (centroid: Double, alpha: Double) {
            let synth = VowelSynthesizer(sampleRate: sampleRate, f0: 150,
                                         formants: VowelSynthesizer.masculineAh,
                                         sourceTiltDbPerOctave: tilt)
            let spectrum = try #require(analyzer.spectrum(synth.render(duration: 0.2)))
            return (try #require(spectrum.centroid(from: 100, to: 8000)),
                    try #require(spectrum.alphaRatio()))
        }
        let bright = try measures(tilt: 6), mid = try measures(tilt: 12), dark = try measures(tilt: 18)
        #expect(bright.centroid > mid.centroid && mid.centroid > dark.centroid)
        #expect(bright.alpha > mid.alpha && mid.alpha > dark.alpha)
        // Halving the harmonic slope should move the alpha ratio by several dB.
        #expect(bright.alpha - dark.alpha > 6)
    }

    @Test("corrected H1-H2 recovers the source tilt", arguments: [6.0, 12.0, 18.0], [110.0, 180.0])
    func correctedH1H2(tilt: Double, f0: Double) throws {
        let analyzer = SpectrumAnalyzer(sampleRate: sampleRate)
        let formants = VowelSynthesizer.masculineAh
        let synth = VowelSynthesizer(sampleRate: sampleRate, f0: f0, formants: formants,
                                     sourceTiltDbPerOctave: tilt)
        let spectrum = try #require(analyzer.spectrum(synth.render(duration: 0.2)))
        let known = formants.map { Formant(frequency: $0.frequency, bandwidth: $0.bandwidth) }
        let raw = try #require(HarmonicMeasures.h1h2(spectrum: spectrum, f0: f0))
        let corrected = try #require(HarmonicMeasures.correctedH1H2(spectrum: spectrum, f0: f0, formants: known))
        // Source harmonics fall by `tilt` dB per octave, so H1-H2 of the source is `tilt`.
        #expect(abs(corrected - tilt) < 1.5, "raw \(raw), corrected \(corrected)")
        // The uncorrected value is pulled down by the F1 skirt boosting H2.
        #expect(raw < corrected)
    }

    @Test("vocal tract length from textbook formants")
    func vocalTractLength() throws {
        let masculine = try #require(VocalTract.length(formants: [500, 1500, 2500]))
        let feminine = try #require(VocalTract.length(formants: [600, 1800, 3000]))
        #expect(abs(masculine - 17.5) < 0.01)
        #expect(abs(feminine - 14.58) < 0.01)
        #expect(VocalTract.length(formants: [500]) == nil)
    }

    @Test("gauges clamp and map linearly")
    func gauges() {
        let calibration = Calibration()
        #expect(calibration.resonanceGauge(vocalTractLength: 18.5) == 0)
        #expect(calibration.resonanceGauge(vocalTractLength: 13.5) == 100)
        #expect(calibration.resonanceGauge(vocalTractLength: 16) == 50)
        #expect(calibration.resonanceGauge(vocalTractLength: 25) == 0)
        #expect(calibration.weightGauge(h1h2: 12) == 0)
        #expect(calibration.weightGauge(h1h2: -3) == 100)
        #expect(calibration.weightGauge(h1h2: 4.5) == 50)
    }
}

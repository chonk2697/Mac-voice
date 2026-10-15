import Foundation
import Testing
@testable import VoiceAnalysis

@Suite("Formant tracking")
struct TrackerTests {
    let steady = [500.0, 1500, 2500].map { Formant(frequency: $0, bandwidth: 100) }

    private func frequencies(_ slots: [Formant?]) -> [Double?] { slots.map { $0?.frequency } }

    @Test("frames are decided lookahead frames late and flush drains the rest")
    func lookahead() {
        var tracker = FormantTracker(lookahead: 3)
        var decided: [[Formant?]] = []
        for i in 0..<10 {
            let out = tracker.push(steady)
            #expect(out.count == (i < 3 ? 0 : 1), "push \(i) decided \(out.count)")
            decided += out
        }
        #expect(tracker.pendingCount == 3)
        decided += tracker.flush()
        #expect(tracker.pendingCount == 0)
        #expect(decided.count == 10)
        #expect(decided.allSatisfy { frequencies($0) == [500, 1500, 2500] })
    }

    @Test("no lookahead decides every frame at once")
    func noLookahead() {
        var tracker = FormantTracker(lookahead: 0)
        for _ in 0..<5 {
            #expect(tracker.push(steady).count == 1)
        }
        #expect(tracker.flush().isEmpty)
    }

    @Test("a wide pole between F1 and F2 is passed over")
    func widePoleSkipped() {
        var tracker = FormantTracker(lookahead: 2)
        var decided: [[Formant?]] = []
        for i in 0..<12 {
            var candidates = steady
            if i % 3 == 1 { candidates.insert(Formant(frequency: 1000, bandwidth: 900), at: 1) }
            decided += tracker.push(candidates)
        }
        decided += tracker.flush()
        #expect(decided.count == 12)
        #expect(decided.allSatisfy { frequencies($0) == [500, 1500, 2500] })
    }

    @Test("poles outside the plausible span are ignored")
    func outsideSpan() {
        var tracker = FormantTracker(lookahead: 1)
        var decided: [[Formant?]] = []
        for _ in 0..<6 {
            let candidates = [Formant(frequency: 100, bandwidth: 40)] + steady + [Formant(frequency: 4600, bandwidth: 80)]
            decided += tracker.push(candidates)
        }
        decided += tracker.flush()
        #expect(decided.allSatisfy { frequencies($0) == [500, 1500, 2500] })
    }

    @Test("a slot whose candidate vanishes stays empty instead of taking the next formant")
    func missingSlot() {
        var tracker = FormantTracker(lookahead: 2)
        var decided: [[Formant?]] = []
        for i in 0..<8 {
            decided += tracker.push(i == 4 ? [steady[0], steady[2]] : steady)
        }
        decided += tracker.flush()
        #expect(frequencies(decided[3]) == [500, 1500, 2500])
        #expect(frequencies(decided[4]) == [500, nil, 2500])
        #expect(frequencies(decided[5]) == [500, 1500, 2500])
    }

    @Test("tracks follow candidates that glide")
    func glide() {
        var tracker = FormantTracker(lookahead: 5)
        let from = [800.0, 1200, 2800], to = [300.0, 2400, 3200]
        var expected: [[Double]] = []
        var decided: [[Formant?]] = []
        for i in 0...30 {
            let t = Double(i) / 30
            let set = zip(from, to).map { exp(log($0) + t * (log($1) - log($0))) }
            expected.append(set)
            decided += tracker.push(set.map { Formant(frequency: $0, bandwidth: 120) })
        }
        decided += tracker.flush()
        #expect(decided.count == expected.count)
        for (slots, set) in zip(decided, expected) {
            #expect(frequencies(slots) == set.map { Optional($0) })
        }
    }

    @Test("empty frames yield empty slots and do not break the run")
    func emptyFrame() {
        var tracker = FormantTracker(lookahead: 1)
        var decided: [[Formant?]] = []
        for i in 0..<5 {
            decided += tracker.push(i == 2 ? [] : steady)
        }
        decided += tracker.flush()
        #expect(frequencies(decided[2]) == [nil, nil, nil])
        #expect(frequencies(decided[3]) == [500, 1500, 2500])
    }

    @Test("the analyzer tracks a synthesized vowel glide")
    func analyzerGlide() throws {
        // Feminine /a/ to /i/ over one second: F1 falls, F2 rises past 2 kHz.
        // F4 and F5 are present as in real speech, so that the LPC's five pole
        // pairs are all spoken for; with only three resonances the spare poles
        // model the source slope and one can land below F1.
        let upper = [VowelSynthesizer.Formant(3800, bandwidth: 200), VowelSynthesizer.Formant(4700, bandwidth: 250)]
        let from = VowelSynthesizer.feminineAh + upper, to = VowelSynthesizer.feminineEe + upper
        let duration = 1.0
        let synth = VowelSynthesizer(f0: 200, formants: from)
        let audio = synth.render(duration: duration) { t in
            VowelSynthesizer.interpolate(from, to, t / duration)
        } + [Float](repeating: 0, count: 4800)

        let analyzer = VoiceAnalyzer()
        var frames: [VoiceFrame] = []
        for start in stride(from: 0, to: audio.count, by: 512) {
            frames += analyzer.process(Array(audio[start..<min(start + 512, audio.count)]))
        }
        frames += analyzer.flush()

        let voiced = frames.filter { $0.isVoiced && $0.time > 0.15 && $0.time < duration - 0.05 }
        #expect(voiced.count > 35)
        var good = 0
        var complete = 0
        var mismatches: [String] = []
        for frame in voiced {
            let centre = frame.time - analyzer.formantWindowDelay
            let truth = VowelSynthesizer.interpolate(from, to, centre / duration)
            guard frame.formants.count == 3 else { continue }
            complete += 1
            let close = zip(frame.formants, truth.prefix(3)).allSatisfy { found, expected in
                abs(found.frequency - expected.frequency) < max(0.1 * expected.frequency, 100)
            }
            if close {
                good += 1
            } else if mismatches.count < 6 {
                mismatches.append(String(format: "%.2fs found %@ expected %@", frame.time,
                                         frame.formants.map { String(format: "%.0f", $0.frequency) }.joined(separator: "/"),
                                         truth.prefix(3).map { String(format: "%.0f", $0.frequency) }.joined(separator: "/")))
            }
        }
        #expect(Double(complete) >= 0.9 * Double(voiced.count), "\(complete) of \(voiced.count) frames had F1 to F3")
        #expect(Double(good) >= 0.9 * Double(voiced.count),
                "\(good) of \(voiced.count) frames followed the glide; \(mismatches.joined(separator: "; "))")
    }
}

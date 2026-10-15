import Foundation
import Testing
@testable import VoiceAnalysis

@Suite("Analyzer pipeline")
struct AnalyzerTests {
    @Test("ring buffer returns the latest samples in order across the wrap")
    func ringBuffer() {
        var ring = RingBuffer(capacity: 5)
        ring.append([1, 2, 3])
        #expect(ring.latest(2) == [2, 3])
        ring.append([4, 5, 6, 7])
        #expect(ring.filled == 5)
        #expect(ring.latest(5) == [3, 4, 5, 6, 7])
        #expect(ring.latest(10) == [3, 4, 5, 6, 7])
    }

    @Test("a synthesized vowel produces voiced frames with the right measurements")
    func vowelFrames() throws {
        let analyzer = VoiceAnalyzer()
        let f0 = 160.0
        let formants = VowelSynthesizer.feminineAh
        let synth = VowelSynthesizer(f0: f0, formants: formants, sourceTiltDbPerOctave: 12)
        let audio = synth.render(duration: 1.0) + [Float](repeating: 0, count: 8000)

        var frames: [VoiceFrame] = []
        for start in stride(from: 0, to: audio.count, by: 256) {
            frames += analyzer.process(Array(audio[start..<min(start + 256, audio.count)]))
        }
        // 1.5 s at a 20 ms hop.
        #expect(abs(frames.count - 75) <= 1)

        let voiced = frames.filter { $0.isVoiced && $0.time > 0.15 && $0.time < 0.98 }
        #expect(voiced.count > 35)
        for frame in voiced {
            let pitch = try #require(frame.pitch)
            #expect(abs(pitch - f0) / f0 < 0.01)
            #expect(frame.formants.count == 3, "\(frame.formants)")
            let vtl = try #require(frame.vocalTractLength)
            #expect(vtl > 12 && vtl < 20)
            let h1h2 = try #require(frame.h1h2)
            #expect(abs(h1h2 - 12) < 3)
            let centroid = try #require(frame.centroid)
            #expect(centroid > 200 && centroid < 4000)
            let alpha = try #require(frame.alphaRatio)
            #expect(alpha > -60 && alpha < 10)
        }
        let silent = frames.filter { $0.time > 1.1 }
        #expect(!silent.isEmpty)
        #expect(silent.allSatisfy { !$0.isVoiced && $0.pitch == nil })
    }
}

@Suite("Smoothing and timelines")
struct TimelineTests {
    @Test("timed median smooths and releases after the hold time")
    func timedMedian() {
        var smoother = TimedMedian(window: 0.15, hold: 0.3)
        #expect(smoother.push(100, at: 0.00) == 100)
        #expect(smoother.push(300, at: 0.02) == 200)
        #expect(smoother.push(110, at: 0.04) == 110)
        #expect(smoother.push(nil, at: 0.20) == 110)   // still within hold
        #expect(smoother.push(nil, at: 0.40) == nil)   // hold expired
    }

    @Test("timeline bins, trims and summarises")
    func timeline() {
        var timeline = Timeline(resolution: 0.1, capacity: 2)
        for i in 0..<300 {   // 6 s at 20 ms
            let t = Double(i) * 0.02
            timeline.append(t < 3 ? 100 : 200, at: t)
        }
        let now = 299 * 0.02
        let recent = timeline.points(window: 1, now: now)
        #expect(recent.count >= 9 && recent.count <= 11)
        #expect(recent.allSatisfy { $0.value == 200 })
        #expect(timeline.median(window: 1, now: now) == 200)
        #expect(timeline.points(window: 10, now: now).first!.time >= now - 2.2)
        #expect(timeline.points(window: 1, now: now, maxPoints: 3).count == 3)
    }
}

@Suite("Session")
struct SessionTests {
    private func frame(at time: TimeInterval, pitch: Double?, f1: Double = 700, vtl: Double = 16) -> VoiceFrame {
        guard let pitch else { return VoiceFrame(time: time, level: -70) }
        let formants = [Formant(frequency: f1, bandwidth: 80),
                        Formant(frequency: 2 * f1, bandwidth: 100),
                        Formant(frequency: 3.5 * f1, bandwidth: 150)]
        return VoiceFrame(time: time, level: -20, isVoiced: true, pitch: pitch, clarity: 0.9,
                          formants: formants, vocalTractLength: vtl, h1h2: 5, centroid: 1500, alphaRatio: -15)
    }

    @Test("resonance follows a three second median, pitch a fast one")
    func slowMetrics() {
        let session = VoiceSession()
        for i in 0..<100 { session.ingest(frame(at: Double(i) * 0.02, pitch: 150, vtl: 18)) }   // 2 s
        for i in 100..<150 { session.ingest(frame(at: Double(i) * 0.02, pitch: 200, vtl: 12)) } // 1 s
        #expect(session.current[.pitch] == 200)
        #expect(session.current[.vocalTractLength] == 18)   // 2 s of 18 outweigh 1 s of 12
        for i in 150..<260 { session.ingest(frame(at: Double(i) * 0.02, pitch: 200, vtl: 12)) }
        #expect(session.current[.vocalTractLength] == 12)
        for i in 260..<330 { session.ingest(frame(at: Double(i) * 0.02, pitch: nil)) }           // 1.4 s silence
        #expect(session.current[.pitch] == nil)
        #expect(session.current[.vocalTractLength] == 12)   // held for 2 s
        for i in 330..<380 { session.ingest(frame(at: Double(i) * 0.02, pitch: nil)) }
        #expect(session.current[.vocalTractLength] == nil)
    }

    @Test("current values follow the smoother and drop out in silence")
    func currentValues() {
        let session = VoiceSession()
        for i in 0..<10 { session.ingest(frame(at: Double(i) * 0.02, pitch: 150)) }
        #expect(session.current[.pitch] == 150)
        #expect(session.current[.f1] == 700)
        for i in 10..<40 { session.ingest(frame(at: Double(i) * 0.02, pitch: nil)) }
        #expect(session.current[.pitch] == nil)
        #expect(session.lastVoicedTime == 9 * 0.02)
    }

    @Test("baseline recording captures medians and formant shift is relative to it")
    func baselineAndShift() throws {
        let session = VoiceSession()
        session.startBaselineRecording(duration: 2)
        for i in 0..<120 { session.ingest(frame(at: Double(i) * 0.02, pitch: 140, f1: 600)) }
        let baseline = try #require(session.baseline)
        #expect(baseline.medians[.pitch] == 140)
        #expect(baseline.medians[.f1] == 600)
        #expect(session.recording == nil)

        for i in 120..<300 { session.ingest(frame(at: Double(i) * 0.02, pitch: 180, f1: 660)) }
        let shift = try #require(session.formantShift())
        #expect(abs(shift - 0.10) < 0.01)
    }

    @Test("drift compares the recent window with the session")
    func drift() throws {
        let session = VoiceSession()
        for i in 0..<1000 { session.ingest(frame(at: Double(i) * 0.02, pitch: 160)) }
        for i in 1000..<1500 { session.ingest(frame(at: Double(i) * 0.02, pitch: 120)) }
        let drift = try #require(session.drift(.pitch, recent: 5, reference: 30))
        // Recent 5 s are at 120; the 30 s reference is 20 s at 160 and 10 s at 120.
        #expect(drift < -20 && drift > -45)
    }
}

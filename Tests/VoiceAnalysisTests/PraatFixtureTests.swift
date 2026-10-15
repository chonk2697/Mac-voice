import Foundation
import Testing
@testable import VoiceAnalysis

/// Tolerance tests against formant tracks that Praat produced offline for a
/// public-domain-licensed speech excerpt in `Tests/Fixtures`. Praat's
/// "To Formant (burg)" is the reference the design targets, so this is the
/// guard against the estimator drifting away from it on real speech.
@Suite("Praat reference fixtures")
struct PraatFixtureTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    struct PraatFrame: Decodable {
        var time: Double
        var pitch: Double?
        /// `[frequency, bandwidth]` for F1 upwards.
        var formants: [[Double]]
    }

    struct PraatTrack: Decodable {
        var ceiling: Double
        var frames: [PraatFrame]
    }

    /// Reads a 16-bit PCM mono WAV. Only what the fixtures need.
    static func readWav(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let data = try Data(contentsOf: url)
        func u32(_ offset: Int) -> UInt32 {
            data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        func u16(_ offset: Int) -> UInt16 {
            data[offset..<offset + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        }
        try #require(data.count > 12 && String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        var offset = 12
        var sampleRate = 0.0
        var channels = 0
        var bits = 0
        var samples: [Float] = []
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(u32(offset + 4))
            let body = offset + 8
            if id == "fmt " {
                channels = Int(u16(body + 2))
                sampleRate = Double(u32(body + 4))
                bits = Int(u16(body + 14))
            } else if id == "data" {
                try #require(channels == 1 && bits == 16, "fixture must be 16-bit mono")
                let count = min(size, data.count - body) / 2
                samples.reserveCapacity(count)
                for i in 0..<count {
                    samples.append(Float(Int16(bitPattern: u16(body + 2 * i))) / 32768)
                }
            }
            offset = body + size + (size & 1)
        }
        return (samples, sampleRate)
    }

    /// Per-formant comparison over 100 ms bins of Praat's voiced frames.
    struct Comparison {
        var bins = 0
        var coverage = 0.0
        var medianError = 0.0
        var medianAbsoluteError = 0.0
        var grossErrorFraction = 0.0
    }

    static func compare(_ frames: [VoiceFrame], windowDelay: Double, against praat: [PraatFrame],
                        binWidth: Double = 0.1) -> [Comparison] {
        var praatBins: [Int: [PraatFrame]] = [:]
        for frame in praat where frame.pitch != nil {
            praatBins[Int((frame.time / binWidth).rounded(.down)), default: []].append(frame)
        }
        var ourBins: [Int: [VoiceFrame]] = [:]
        for frame in frames where frame.isVoiced {
            ourBins[Int(((frame.time - windowDelay) / binWidth).rounded(.down)), default: []].append(frame)
        }
        return (0..<3).map { k in
            var errors: [Double] = []
            var reference = 0
            for (bin, praatFrames) in praatBins where praatFrames.count >= 3 {
                let praatValues = praatFrames.compactMap { $0.formants.count > k ? $0.formants[k][0] : nil }
                guard praatValues.count >= 3, let expected = TimedMedian.median(praatValues) else { continue }
                reference += 1
                let ourValues = (ourBins[bin] ?? []).compactMap { $0.formants.count > k ? $0.formants[k].frequency : nil }
                guard ourValues.count >= 2, let found = TimedMedian.median(ourValues) else { continue }
                errors.append(found / expected - 1)
            }
            var result = Comparison(bins: errors.count)
            guard !errors.isEmpty else { return result }
            result.coverage = Double(errors.count) / Double(max(reference, 1))
            result.medianError = TimedMedian.median(errors) ?? 0
            result.medianAbsoluteError = TimedMedian.median(errors.map(abs)) ?? 0
            result.grossErrorFraction = Double(errors.filter { abs($0) > 0.2 }.count) / Double(errors.count)
            return result
        }
    }

    @Test("F1 to F3 agree with Praat on a public speech excerpt")
    func librispeechExcerpt() throws {
        let name = "librispeech-198-209-0000-excerpt"
        let (samples, rate) = try Self.readWav(Self.fixtures.appendingPathComponent("\(name).wav"))
        #expect(rate == 16_000)
        #expect(samples.count > 16_000)
        let track = try JSONDecoder().decode(
            PraatTrack.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).praat.json")))
        #expect(track.ceiling == 5500)

        let analyzer = VoiceAnalyzer()
        var frames: [VoiceFrame] = []
        for start in stride(from: 0, to: samples.count, by: 1024) {
            frames += analyzer.process(Array(samples[start..<min(start + 1024, samples.count)]))
        }
        frames += analyzer.flush()

        let results = Self.compare(frames, windowDelay: analyzer.formantWindowDelay, against: track.frames)
        for (k, result) in results.enumerated() {
            let label = Comment(rawValue: "F\(k + 1): \(result.bins) bins, coverage \(result.coverage), "
                + "median error \(result.medianError), median |error| \(result.medianAbsoluteError), "
                + "gross \(result.grossErrorFraction)")
            #expect(result.bins >= 20, label)
            #expect(result.coverage >= 0.75, label)
            #expect(abs(result.medianError) < 0.06, label)
            #expect(result.medianAbsoluteError < 0.08, label)
            #expect(result.grossErrorFraction < 0.25, label)
        }

        let withF3 = frames.filter { $0.isVoiced && $0.formants.count == 3 }
        let highF3 = withF3.filter { $0.formants[2].frequency > 3800 }
        #expect(Double(highF3.count) < 0.05 * Double(max(withF3.count, 1)),
                "\(highF3.count) of \(withF3.count) frames put F3 above 3.8 kHz")
    }
}

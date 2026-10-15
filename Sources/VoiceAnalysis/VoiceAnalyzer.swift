import Foundation

/// Fixed-capacity sample history.
struct RingBuffer {
    private var storage: [Float]
    private var writeIndex = 0
    private(set) var filled = 0

    init(capacity: Int) {
        storage = [Float](repeating: 0, count: capacity)
    }

    var capacity: Int { storage.count }

    mutating func append(_ samples: [Float]) {
        for s in samples {
            storage[writeIndex] = s
            writeIndex = (writeIndex + 1) % storage.count
        }
        filled = min(storage.count, filled + samples.count)
    }

    /// The most recent `count` samples in chronological order.
    func latest(_ count: Int) -> [Float] {
        let n = min(count, filled)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        var index = (writeIndex - n + storage.count) % storage.count
        for i in 0..<n {
            out[i] = storage[index]
            index = (index + 1) % storage.count
        }
        return out
    }
}

/// Everything measured on one analysis hop.
public struct VoiceFrame: Sendable, Equatable {
    /// Seconds since the analyzer started.
    public var time: TimeInterval
    /// Level in dB relative to full scale.
    public var level: Double
    public var isVoiced: Bool
    /// Fundamental frequency in Hz.
    public var pitch: Double?
    public var clarity: Double?
    /// Lowest formants first; empty when unvoiced or not found.
    public var formants: [Formant]
    /// Estimated vocal tract length in cm.
    public var vocalTractLength: Double?
    /// H1*-H2* in dB when formants were available, otherwise raw H1-H2.
    public var h1h2: Double?
    /// Spectral centroid in Hz.
    public var centroid: Double?
    /// Alpha ratio in dB: energy above 1 kHz relative to below. Higher is brighter.
    public var alphaRatio: Double?

    public init(time: TimeInterval, level: Double, isVoiced: Bool = false,
                pitch: Double? = nil, clarity: Double? = nil, formants: [Formant] = [],
                vocalTractLength: Double? = nil, h1h2: Double? = nil, centroid: Double? = nil,
                alphaRatio: Double? = nil) {
        self.time = time
        self.level = level
        self.isVoiced = isVoiced
        self.pitch = pitch
        self.clarity = clarity
        self.formants = formants
        self.vocalTractLength = vocalTractLength
        self.h1h2 = h1h2
        self.centroid = centroid
        self.alphaRatio = alphaRatio
    }
}

public struct AnalyzerConfiguration: Sendable, Equatable {
    public var sampleRate = 16_000.0
    /// Samples between analysis frames (20 ms at 16 kHz).
    public var hop = 320
    /// Frames quieter than this are treated as silence.
    public var levelGateDb = -50.0
    /// Voicing also requires this much energy inside `speechBand`, which keeps
    /// mains hum and rumble from counting as speech.
    public var speechBandGateDb = -50.0
    public var speechBand = 200.0...4000.0
    /// High-pass cutoff applied to the input; 0 disables it.
    public var highPassHz = 75.0
    public var minPitch = 65.0
    public var maxPitch = 600.0
    /// Centroid band in Hz.
    public var centroidBand = 100.0...8000.0
    /// Vocal tract length estimates outside this range are discarded as
    /// implausible for an adult.
    public var vocalTractLengthRange = 9.0...23.0
    /// Formant sets with F1 or F2 above these are discarded; they come from
    /// clicks, breaths and other non-speech sounds rather than vowels.
    public var maxF1 = 1200.0
    public var maxF2 = 3600.0
    /// Frames the formant tracker looks ahead before deciding a frame; voiced
    /// frames are delayed by this many hops (100 ms at the defaults).
    public var formantLookahead = 5

    public init() {}
}

/// Turns a continuous mono sample stream into `VoiceFrame`s, one per hop.
///
/// Voiced frames come out `formantLookahead` hops late, once the formant
/// tracker has seen what follows them; unvoiced frames come out at once,
/// after any voiced frames still pending. Not thread-safe; the app owns one
/// instance inside an actor.
public final class VoiceAnalyzer {
    public let configuration: AnalyzerConfiguration
    private let pitchDetector: YINPitchDetector
    private let formantEstimator: FormantEstimator
    private var formantTracker: FormantTracker
    private let spectrumAnalyzer: SpectrumAnalyzer
    private var ring: RingBuffer
    private var highPass: HighPassFilter?
    private var samplesSinceHop = 0
    private var samplesSeen = 0
    private let levelWindow: Int
    /// Voiced frames waiting for the tracker to decide their formants.
    private var pending: [(frame: VoiceFrame, spectrum: Spectrum)] = []

    public init(configuration: AnalyzerConfiguration = AnalyzerConfiguration()) {
        self.configuration = configuration
        let rate = configuration.sampleRate
        pitchDetector = YINPitchDetector(sampleRate: rate, minFrequency: configuration.minPitch,
                                         maxFrequency: configuration.maxPitch)
        // The tracker judges bandwidth itself, so it sees wide poles too.
        formantEstimator = FormantEstimator(sampleRate: rate, maxBandwidth: 1500)
        formantTracker = FormantTracker(lookahead: configuration.formantLookahead)
        spectrumAnalyzer = SpectrumAnalyzer(sampleRate: rate)
        levelWindow = Int(0.032 * rate)
        if configuration.highPassHz > 0 {
            highPass = HighPassFilter(sampleRate: rate, cutoff: configuration.highPassHz)
        }
        let needed = max(pitchDetector.requiredSamples, formantEstimator.requiredSamples,
                         spectrumAnalyzer.requiredSamples, levelWindow)
        ring = RingBuffer(capacity: needed * 2)
    }

    /// Seconds between a frame's `time` and the centre of its formant window.
    public var formantWindowDelay: Double { formantEstimator.windowCentreDelay }

    /// Decides and returns the voiced frames still held back by the tracker's
    /// lookahead, for the end of a file or a pause in capture.
    public func flush() -> [VoiceFrame] {
        finish(formantTracker.flush())
    }

    /// Appends samples and returns a frame for every hop boundary crossed.
    public func process(_ input: [Float]) -> [VoiceFrame] {
        let samples = highPass != nil ? highPass!.process(input) : input
        var frames: [VoiceFrame] = []
        var offset = 0
        while offset < samples.count {
            let take = min(configuration.hop - samplesSinceHop, samples.count - offset)
            ring.append(Array(samples[offset..<(offset + take)]))
            offset += take
            samplesSinceHop += take
            samplesSeen += take
            if samplesSinceHop >= configuration.hop {
                samplesSinceHop = 0
                frames += analyzeCurrentFrame()
            }
        }
        return frames
    }

    private func analyzeCurrentFrame() -> [VoiceFrame] {
        let time = Double(samplesSeen) / configuration.sampleRate
        let level = Double(Signal.decibels(Signal.rms(ring.latest(levelWindow))))
        var frame = VoiceFrame(time: time, level: level)
        guard level >= configuration.levelGateDb,
              ring.filled >= max(pitchDetector.requiredSamples, spectrumAnalyzer.requiredSamples),
              let spectrum = spectrumAnalyzer.spectrum(ring.latest(spectrumAnalyzer.requiredSamples)),
              let speechLevel = spectrum.bandLevel(from: configuration.speechBand.lowerBound,
                                                   to: configuration.speechBand.upperBound),
              speechLevel >= configuration.speechBandGateDb,
              let pitch = pitchDetector.estimate(ring.latest(pitchDetector.requiredSamples)) else {
            // A voicing break: whatever is pending gets decided on what it has.
            return finish(formantTracker.flush()) + [frame]
        }
        frame.isVoiced = true
        frame.pitch = pitch.frequency
        frame.clarity = pitch.clarity
        frame.centroid = spectrum.centroid(from: configuration.centroidBand.lowerBound,
                                           to: configuration.centroidBand.upperBound)
        frame.alphaRatio = spectrum.alphaRatio()

        let candidates = formantEstimator.candidates(ring.latest(formantEstimator.requiredSamples))
        pending.append((frame, spectrum))
        return finish(formantTracker.push(candidates))
    }

    /// Applies the tracker's decisions to the oldest pending frames, in order.
    private func finish(_ decisions: [[Formant?]]) -> [VoiceFrame] {
        var frames: [VoiceFrame] = []
        for slots in decisions {
            guard !pending.isEmpty else { break }
            var (frame, spectrum) = pending.removeFirst()
            // Keep the filled prefix, so that index i is always F(i + 1).
            var formants: [Formant] = []
            for slot in slots {
                guard let formant = slot else { break }
                formants.append(formant)
            }
            if let f1 = formants.first?.frequency, f1 > configuration.maxF1 { formants = [] }
            if formants.count > 1, formants[1].frequency > configuration.maxF2 { formants = [] }
            frame.formants = formants
            if formants.count >= 2,
               let length = VocalTract.length(formants: formants.map(\.frequency)),
               configuration.vocalTractLengthRange.contains(length) {
                frame.vocalTractLength = length
            }
            if let f0 = frame.pitch {
                frame.h1h2 = formants.isEmpty
                    ? HarmonicMeasures.h1h2(spectrum: spectrum, f0: f0)
                    : HarmonicMeasures.correctedH1H2(spectrum: spectrum, f0: f0, formants: formants)
            }
            frames.append(frame)
        }
        return frames
    }
}

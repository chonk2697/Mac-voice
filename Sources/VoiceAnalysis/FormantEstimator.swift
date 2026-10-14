import Foundation

/// One vocal tract resonance.
public struct Formant: Sendable, Equatable {
    /// Centre frequency in hertz.
    public var frequency: Double
    /// Bandwidth in hertz (3 dB).
    public var bandwidth: Double

    public init(frequency: Double, bandwidth: Double) {
        self.frequency = frequency
        self.bandwidth = bandwidth
    }
}

/// Formant estimation from one short frame, following Praat's recipe:
/// resample so that the ceiling of interest is the Nyquist frequency,
/// pre-emphasise, apply a Gaussian window, fit Burg LPC, then read the
/// formants off the angles of the prediction polynomial's roots.
///
/// Frame-to-frame continuity is left to the caller (median smoothing in
/// `VoiceAnalyzer`), which is enough for a live display.
public struct FormantEstimator: Sendable {
    /// Sample rate of the audio handed to `estimate`.
    public let sampleRate: Double
    /// Sample rate the LPC runs at, 2/3 of the input by default so that the
    /// analysis ceiling is about 5.3 kHz, close to Praat's 5.5 kHz.
    public let analysisSampleRate: Double
    /// LPC order at the analysis rate.
    public let order: Int
    /// Analysis window length in samples at the analysis rate.
    public let windowLength: Int
    /// Candidates below this frequency are treated as source poles, not formants.
    public let minFormantFrequency: Double
    /// Bandwidth ceilings for candidates below 1 kHz, between 1 and 2 kHz, and
    /// above 2 kHz. Low formants are narrow in real speech, so a wide low pole
    /// is almost always the source or the window, while F3 and above are
    /// genuinely wider and LPC overestimates their bandwidth.
    public let bandwidthCeilings: (low: Double, mid: Double, high: Double)
    /// How many formants to return, lowest first.
    public let maxFormants: Int

    private let resampler: Resampler?
    private let window: [Float]

    public init(sampleRate: Double,
                order: Int = 10,
                windowDuration: Double = 0.030,
                resampleUp: Int = 2, resampleDown: Int = 3,
                minFormantFrequency: Double = 90,
                bandwidthCeilings: (low: Double, mid: Double, high: Double) = (250, 400, 600),
                maxFormants: Int = 3) {
        self.sampleRate = sampleRate
        if resampleUp == resampleDown {
            self.resampler = nil
            self.analysisSampleRate = sampleRate
        } else {
            self.resampler = Resampler(up: resampleUp, down: resampleDown)
            self.analysisSampleRate = sampleRate * Double(resampleUp) / Double(resampleDown)
        }
        self.order = order
        self.windowLength = Int(windowDuration * analysisSampleRate)
        self.minFormantFrequency = minFormantFrequency
        self.bandwidthCeilings = bandwidthCeilings
        self.maxFormants = maxFormants
        self.window = Window.gaussian(windowLength)
    }

    /// Number of input samples `estimate` needs.
    public var requiredSamples: Int {
        resampler?.inputCount(forOutputs: windowLength) ?? windowLength
    }

    /// Estimates the formants of the most recent samples of `x`.
    /// Returns an empty array for silence or when no plausible formants exist.
    public func estimate(_ x: [Float]) -> [Formant] {
        guard x.count >= requiredSamples else { return [] }
        var frame = Array(x[(x.count - requiredSamples)...])
        if let resampler {
            frame = resampler.resample(frame)
        }
        guard frame.count >= windowLength else { return [] }
        frame = Array(frame[(frame.count - windowLength)...])

        let emphasised = Signal.preEmphasis(frame, sampleRate: analysisSampleRate)
        let windowed = Signal.multiply(emphasised, window).map(Double.init)
        guard let (a, _) = LinearPrediction.burg(windowed, order: order) else { return [] }

        // A(z) * z^order is monic with coefficients a[1...order].
        let roots = Polynomial.roots(monic: Array(a[1...]))
        let ceiling = analysisSampleRate / 2 - 50

        var candidates: [Formant] = []
        for root in roots where root.im > 0 && root.magnitude < 1 {
            let frequency = root.phase * analysisSampleRate / (2 * .pi)
            let bandwidth = -log(root.magnitude) * analysisSampleRate / .pi
            guard frequency >= minFormantFrequency,
                  frequency <= ceiling,
                  bandwidth <= maxBandwidth(at: frequency) else { continue }
            candidates.append(Formant(frequency: frequency, bandwidth: bandwidth))
        }
        candidates.sort { $0.frequency < $1.frequency }
        return Array(candidates.prefix(maxFormants))
    }

    public func maxBandwidth(at frequency: Double) -> Double {
        switch frequency {
        case ..<1000: bandwidthCeilings.low
        case ..<2000: bandwidthCeilings.mid
        default: bandwidthCeilings.high
        }
    }
}

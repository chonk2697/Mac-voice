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
/// pre-emphasise, apply a Gaussian window, fit Burg LPC, then read candidate
/// formants off the angles of the prediction polynomial's roots.
///
/// `candidates` is the raw list for `FormantTracker`, which adds continuity
/// across frames. `estimate` assigns one frame's candidates to F1, F2, F3 by
/// a plausibility search instead: each slot has a typical frequency range,
/// wide poles are penalised, and lower candidates are mildly preferred.
///
/// The defaults match Praat's "To Formant (burg)" for a female-range voice
/// (ceiling 5.5 kHz, five formants, pre-emphasis from 50 Hz); measured on
/// connected speech against Praat, a 40 ms Gaussian window at a 20 ms hop
/// offers a candidate within 10 % of Praat's F1, F2 and F3 in 96 to 98 % of
/// voiced frames. A second pre-emphasis pass at the input rate, tried
/// earlier for breathy voices, cost most of F1 and is off.
public struct FormantEstimator: Sendable {
    /// Sample rate of the audio handed to `estimate`.
    public let sampleRate: Double
    /// Sample rate the LPC runs at, 11/16 of the input by default so that the
    /// analysis ceiling is Praat's 5.5 kHz.
    public let analysisSampleRate: Double
    /// LPC order at the analysis rate.
    public let order: Int
    /// Analysis window length in samples at the analysis rate.
    public let windowLength: Int
    /// Apply a first-order pre-emphasis at the input rate before resampling,
    /// in addition to the one at the analysis rate that Praat uses. Off by
    /// default: the extra 6 dB per octave pushes the LPC poles up and loses
    /// F1 on ordinary speech.
    public let preEmphasisBeforeResampling: Bool
    /// Roots below this frequency are never formant candidates.
    public let minFormantFrequency: Double
    /// Roots wider than this are never formant candidates.
    public let maxBandwidth: Double
    /// How many formants to return, lowest first.
    public let maxFormants: Int
    /// Typical frequency range per slot. Candidates outside pay a cost that
    /// grows with the log distance from the nearest edge.
    public let plausibleRanges: [ClosedRange<Double>]
    /// Standard deviation of the Gaussian window as a fraction of its length.
    public let windowSigmaFraction: Double

    private let resampler: Resampler?
    private let window: [Float]

    public init(sampleRate: Double,
                order: Int = 10,
                windowDuration: Double = 0.040,
                resampleUp: Int = 11, resampleDown: Int = 16,
                preEmphasisBeforeResampling: Bool = false,
                minFormantFrequency: Double = 90,
                maxBandwidth: Double = 500,
                maxFormants: Int = 3,
                plausibleRanges: [ClosedRange<Double>] = [150...1100, 500...3200, 1700...4000],
                windowSigmaFraction: Double = 1.0 / 6) {
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
        self.preEmphasisBeforeResampling = preEmphasisBeforeResampling
        self.minFormantFrequency = minFormantFrequency
        self.maxBandwidth = maxBandwidth
        self.maxFormants = maxFormants
        self.plausibleRanges = plausibleRanges
        self.windowSigmaFraction = windowSigmaFraction
        self.window = Window.gaussian(windowLength, sigmaFraction: windowSigmaFraction)
    }

    /// Number of input samples `estimate` needs.
    public var requiredSamples: Int {
        resampler?.inputCount(forOutputs: windowLength) ?? windowLength
    }

    /// Seconds between the last input sample and the centre of the analysis
    /// window: half the window plus the resampler's group delay.
    public var windowCentreDelay: Double {
        var delay = Double(windowLength) / 2 / analysisSampleRate
        if let resampler {
            delay += Double(resampler.taps.count - 1) / 2 / (sampleRate * Double(resampler.up))
        }
        return delay
    }

    /// Estimates the formants of the most recent samples of `x`.
    /// Returns an empty array for silence or when no plausible formants exist.
    public func estimate(_ x: [Float]) -> [Formant] {
        FormantEstimator.select(from: candidates(x), ranges: plausibleRanges, count: maxFormants)
    }

    /// All plausible resonances in the frame, lowest first, before slot assignment.
    public func candidates(_ x: [Float]) -> [Formant] {
        guard x.count >= requiredSamples else { return [] }
        var frame = Array(x[(x.count - requiredSamples)...])
        if let resampler {
            if preEmphasisBeforeResampling {
                frame = Signal.preEmphasis(frame, sampleRate: sampleRate)
            }
            frame = resampler.resample(frame)
        }
        guard frame.count >= windowLength else { return [] }
        frame = Array(frame[(frame.count - windowLength)...])
        frame = Signal.preEmphasis(frame, sampleRate: analysisSampleRate)
        let windowed = Signal.multiply(frame, window).map(Double.init)
        guard let (a, _) = LinearPrediction.burg(windowed, order: order) else { return [] }

        // A(z) * z^order is monic with coefficients a[1...order].
        let roots = Polynomial.roots(monic: Array(a[1...]))
        let ceiling = analysisSampleRate / 2 - 50

        var found: [Formant] = []
        for root in roots where root.im > 0 && root.magnitude < 1 {
            let frequency = root.phase * analysisSampleRate / (2 * .pi)
            let bandwidth = -log(root.magnitude) * analysisSampleRate / .pi
            guard frequency >= minFormantFrequency,
                  frequency <= ceiling,
                  bandwidth <= maxBandwidth else { continue }
            found.append(Formant(frequency: frequency, bandwidth: bandwidth))
        }
        return found.sorted { $0.frequency < $1.frequency }
    }

    /// Cost of placing `frequency` in a slot whose typical range is `range`:
    /// zero inside, otherwise ten times the log distance to the nearest edge
    /// (about 1 per 10 % outside).
    static func rangeCost(_ frequency: Double, _ range: ClosedRange<Double>) -> Double {
        if range.contains(frequency) { return 0 }
        let edge = frequency < range.lowerBound ? range.lowerBound : range.upperBound
        return 10 * abs(log(frequency / edge))
    }

    /// Bandwidth at which a chosen candidate costs one unit. Bandwidth is what
    /// separates a real F1 (up to about 300 Hz when breathy) from a spurious
    /// low pole (usually 350 Hz and wider), so it is weighted heavily.
    static let bandwidthScale = 250.0
    /// Cost per position down the candidate list, to prefer lower candidates.
    static let positionCost = 0.1
    /// Cost of leaving a slot unfilled, so full sets win unless implausible.
    static let missingSlotCost = 3.0
    /// Chosen candidates whose range cost exceeds this end the result.
    static let maxAcceptedRangeCost = 2.0

    /// Assigns candidates to slots in increasing frequency order, minimising
    /// the total of range, bandwidth, position and missing-slot costs.
    static func select(from candidates: [Formant], ranges: [ClosedRange<Double>], count: Int) -> [Formant] {
        let slots = min(count, ranges.count)
        guard slots > 0, !candidates.isEmpty else { return [] }

        var best: [Int] = []
        var bestCost = Double.infinity

        func search(slot: Int, start: Int, chosen: [Int], cost: Double) {
            let total = cost + Double(slots - slot) * missingSlotCost
            if total < bestCost {
                bestCost = total
                best = chosen
            }
            guard slot < slots, start < candidates.count else { return }
            for i in start..<candidates.count {
                let candidate = candidates[i]
                let slotCost = rangeCost(candidate.frequency, ranges[slot])
                    + candidate.bandwidth / bandwidthScale
                    + positionCost * Double(i)
                search(slot: slot + 1, start: i + 1, chosen: chosen + [i], cost: cost + slotCost)
            }
        }
        search(slot: 0, start: 0, chosen: [], cost: 0)

        var result: [Formant] = []
        for (slot, index) in best.enumerated() {
            let candidate = candidates[index]
            guard rangeCost(candidate.frequency, ranges[slot]) <= maxAcceptedRangeCost else { break }
            result.append(candidate)
        }
        return result
    }
}

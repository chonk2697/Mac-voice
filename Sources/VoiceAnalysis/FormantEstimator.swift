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
/// Candidates are assigned to F1, F2, F3 by a plausibility search rather than
/// by taking the three lowest: each slot has a typical frequency range, wide
/// poles are penalised, and lower candidates are mildly preferred. This copes
/// with breathy voices, whose F1 fits come out wide, and with source poles
/// below F1. Frame-to-frame continuity is left to the caller.
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
    /// Apply a first-order pre-emphasis at the input rate before resampling,
    /// in addition to the one at the analysis rate that Praat uses. The extra
    /// pass flattens a breathy source enough for the LPC fit to find F1, and
    /// placing it before the resampler keeps the bandwidth estimates sane.
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

    private let resampler: Resampler?
    private let window: [Float]

    public init(sampleRate: Double,
                order: Int = 10,
                windowDuration: Double = 0.030,
                resampleUp: Int = 2, resampleDown: Int = 3,
                preEmphasisBeforeResampling: Bool = true,
                minFormantFrequency: Double = 90,
                maxBandwidth: Double = 500,
                maxFormants: Int = 3,
                plausibleRanges: [ClosedRange<Double>] = [150...1100, 500...3200, 1700...4000]) {
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
        self.window = Window.gaussian(windowLength)
    }

    /// Number of input samples `estimate` needs.
    public var requiredSamples: Int {
        resampler?.inputCount(forOutputs: windowLength) ?? windowLength
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

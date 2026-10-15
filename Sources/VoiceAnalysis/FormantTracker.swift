import Foundation

/// Assigns per-frame formant candidates to F1, F2 and F3 by fixed-lag
/// Viterbi decoding, the approach of Praat's formant tracker.
///
/// Each voiced frame's candidates (from `FormantEstimator.candidates`, lowest
/// first) define a set of states: every way of filling the slots with
/// candidates in increasing frequency order, including leaving slots empty.
/// A state's local cost prefers candidates near a reference frequency and
/// inside a plausible range, charges for empty slots, and charges for passing
/// over a narrow candidate below the highest chosen one: a real resonance
/// rarely sits between the formants, while a wide pole may be skipped
/// freely. The transition cost charges per octave of movement in each slot.
///
/// A frame is decided `lookahead` frames after it arrives, by backtracking
/// from the best state of the newest frame, so a glitch lasting a frame or
/// two cannot pull a track off course. Unvoiced stretches end a run: callers
/// `flush` at a voicing break and start pushing again at the next.
public struct FormantTracker: Sendable {
    public struct Costs: Sendable, Equatable {
        /// Per natural-log unit of distance from the slot's reference frequency.
        public var reference = 0.25
        /// Per 400 Hz of bandwidth of a chosen candidate.
        public var bandwidth = 0.0
        /// For passing over a candidate below the highest chosen one; scaled
        /// down linearly to nothing at `wideBandwidth`.
        public var skip = 6.0
        public var wideBandwidth = 1000.0
        /// Per octave a slot moves between consecutive frames.
        public var jump = 1.0
        /// For a slot filled in one frame and empty in the next, or the reverse.
        public var `break` = 0.5
        /// Per empty slot.
        public var missing = 3.0
        /// Per natural-log unit outside the slot's plausible range.
        public var range = 10.0

        public init() {}
    }

    /// Frames of delay before a frame's formants are decided.
    public let lookahead: Int
    /// Typical frequency per slot; candidates are pulled gently towards it.
    public let references: [Double]
    /// Plausible frequency range per slot.
    public let ranges: [ClosedRange<Double>]
    /// Candidates wider than this are ignored.
    public let maxBandwidth: Double
    /// Only the lowest this many candidates are considered.
    public let maxCandidates: Int
    public let costs: Costs

    public var slots: Int { references.count }

    private struct Frame {
        var candidates: [Formant]
        /// Candidate index per slot, -1 for an empty slot.
        var states: [[Int]]
        var cumulative: [Double]
        var back: [Int]
    }

    /// The undecided frames, oldest first.
    private var window: [Frame] = []
    private var stateCache: [Int: [[Int]]] = [:]

    public init(lookahead: Int = 5,
                references: [Double] = [560, 1680, 2800],
                ranges: [ClosedRange<Double>] = [150...1100, 500...3200, 1700...4000],
                maxBandwidth: Double = 1500,
                maxCandidates: Int = 8,
                costs: Costs = Costs()) {
        precondition(lookahead >= 0 && references.count == ranges.count && !references.isEmpty)
        self.lookahead = lookahead
        self.references = references
        self.ranges = ranges
        self.maxBandwidth = maxBandwidth
        self.maxCandidates = maxCandidates
        self.costs = costs
    }

    /// Number of frames pushed but not yet decided.
    public var pendingCount: Int { window.count }

    /// Adds one voiced frame's candidates and returns the frames that became
    /// final because of it: usually none until `lookahead` frames are
    /// pending, then one per push. Each result is slot-aligned, nil where the
    /// slot is empty.
    public mutating func push(_ candidates: [Formant]) -> [[Formant?]] {
        // Poles below the lowest plausible F1 or above the highest plausible
        // F3 can never be assigned, so they do not enter the state space.
        let span = ranges[0].lowerBound...ranges[slots - 1].upperBound
        var usable = candidates.filter { $0.bandwidth <= maxBandwidth && span.contains($0.frequency) }
        if usable.count > maxCandidates { usable = Array(usable.prefix(maxCandidates)) }
        let states = states(forCandidateCount: usable.count)
        var cumulative = states.map { localCost(usable, $0) }
        var back = [Int](repeating: -1, count: states.count)

        if let previous = window.last {
            let previousLog = previous.candidates.map { log2($0.frequency) }
            let currentLog = usable.map { log2($0.frequency) }
            for (s, state) in states.enumerated() {
                var best = Double.infinity
                var argument = -1
                for (p, previousState) in previous.states.enumerated() {
                    var cost = previous.cumulative[p]
                    if cost >= best { continue }
                    for k in 0..<slots {
                        let a = previousState[k], b = state[k]
                        if a < 0 && b < 0 { continue }
                        if a < 0 || b < 0 {
                            cost += costs.break
                        } else {
                            cost += costs.jump * abs(currentLog[b] - previousLog[a])
                        }
                    }
                    if cost < best {
                        best = cost
                        argument = p
                    }
                }
                cumulative[s] += best
                back[s] = argument
            }
            // Keep the running costs small; only differences matter.
            let floor = cumulative.min() ?? 0
            for i in cumulative.indices { cumulative[i] -= floor }
        }

        window.append(Frame(candidates: usable, states: states, cumulative: cumulative, back: back))
        var decided: [[Formant?]] = []
        while window.count > lookahead {
            decided.append(decideOldest())
        }
        return decided
    }

    /// Decides every pending frame, oldest first, and ends the run.
    public mutating func flush() -> [[Formant?]] {
        var decided: [[Formant?]] = []
        while !window.isEmpty {
            decided.append(decideOldest())
        }
        return decided
    }

    private mutating func decideOldest() -> [Formant?] {
        let newest = window[window.count - 1]
        var state = 0
        for i in newest.cumulative.indices where newest.cumulative[i] < newest.cumulative[state] {
            state = i
        }
        for t in stride(from: window.count - 1, to: 0, by: -1) {
            state = window[t].back[state]
        }
        let frame = window.removeFirst()
        return frame.states[state].map { $0 < 0 ? nil : frame.candidates[$0] }
    }

    /// Cost of one frame's assignment on its own.
    func localCost(_ candidates: [Formant], _ state: [Int]) -> Double {
        var cost = 0.0
        var top = -1
        for k in 0..<slots {
            let i = state[k]
            if i < 0 {
                cost += costs.missing
                continue
            }
            top = max(top, i)
            let frequency = candidates[i].frequency
            cost += costs.reference * abs(log(frequency / references[k]))
            cost += costs.bandwidth * candidates[i].bandwidth / 400
            cost += costs.range * FormantTracker.rangeDistance(frequency, ranges[k])
        }
        if top > 0 {
            for i in 0..<top where !state.contains(i) {
                cost += costs.skip * max(0, min(1, 1 - candidates[i].bandwidth / costs.wideBandwidth))
            }
        }
        return cost
    }

    /// Natural-log distance from `frequency` to the nearest edge of `range`,
    /// zero inside it.
    static func rangeDistance(_ frequency: Double, _ range: ClosedRange<Double>) -> Double {
        if range.contains(frequency) { return 0 }
        let edge = frequency < range.lowerBound ? range.lowerBound : range.upperBound
        return abs(log(frequency / edge))
    }

    /// Every assignment of `count` candidates to the slots: per slot either
    /// -1 or a candidate index, with the filled indices strictly increasing.
    private mutating func states(forCandidateCount count: Int) -> [[Int]] {
        if let cached = stateCache[count] { return cached }
        var result: [[Int]] = []
        var current = [Int](repeating: -1, count: slots)
        func fill(slot: Int, next: Int) {
            if slot == slots {
                result.append(current)
                return
            }
            current[slot] = -1
            fill(slot: slot + 1, next: next)
            if next < count {
                for i in next..<count {
                    current[slot] = i
                    fill(slot: slot + 1, next: i + 1)
                }
                current[slot] = -1
            }
        }
        fill(slot: 0, next: 0)
        stateCache[count] = result
        return result
    }
}

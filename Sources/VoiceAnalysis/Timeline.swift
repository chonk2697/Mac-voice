import Foundation

/// A timestamped measurement.
public struct TimelinePoint: Sendable, Equatable, Identifiable {
    public var time: TimeInterval
    public var value: Double
    public var id: TimeInterval { time }

    public init(time: TimeInterval, value: Double) {
        self.time = time
        self.value = value
    }
}

/// Median of the values within a short time window; the smoothing used for
/// live readouts. Returns nil once nothing has arrived for `hold` seconds.
public struct TimedMedian: Sendable {
    public let window: TimeInterval
    public let hold: TimeInterval
    private var points: [TimelinePoint] = []
    private var lastOutput: Double?

    public init(window: TimeInterval = 0.15, hold: TimeInterval = 0.3) {
        self.window = window
        self.hold = hold
    }

    /// Records `value` (if any) at `time` and returns the current smoothed
    /// value: the median of the last `window` seconds, held for `hold` seconds
    /// after the last value, then nil.
    public mutating func push(_ value: Double?, at time: TimeInterval) -> Double? {
        if let value { points.append(TimelinePoint(time: time, value: value)) }
        points.removeAll { $0.time < time - max(window, hold) }
        guard let last = points.last, time - last.time <= hold else {
            lastOutput = nil
            return nil
        }
        let recent = points.filter { $0.time >= time - window }.map(\.value)
        if let median = TimedMedian.median(recent) { lastOutput = median }
        return lastOutput
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// History of one metric, binned to a fixed rate so that long windows stay
/// small. Points are kept in memory only.
public struct Timeline: Sendable {
    /// Seconds per stored point.
    public let resolution: TimeInterval
    public let capacity: TimeInterval
    private var points: [TimelinePoint] = []
    private var binIndex: Int?
    private var binValues: [Double] = []

    public init(resolution: TimeInterval = 0.1, capacity: TimeInterval = 600) {
        self.resolution = resolution
        self.capacity = capacity
    }

    /// Adds a sample; nil samples still advance time so gaps are preserved.
    public mutating func append(_ value: Double?, at time: TimeInterval) {
        let index = Int((time / resolution).rounded(.down))
        if let current = binIndex, index != current {
            flushBin()
        }
        binIndex = index
        if let value { binValues.append(value) }
        trim(before: time - capacity)
    }

    private mutating func flushBin() {
        if let index = binIndex, let median = TimedMedian.median(binValues) {
            points.append(TimelinePoint(time: (Double(index) + 0.5) * resolution, value: median))
        }
        binValues.removeAll(keepingCapacity: true)
    }

    private mutating func trim(before cutoff: TimeInterval) {
        if let first = points.first, first.time < cutoff {
            let keepFrom = points.firstIndex { $0.time >= cutoff } ?? points.count
            points.removeFirst(keepFrom)
        }
    }

    /// Points newer than `window` seconds before `now`, thinned to at most
    /// `maxPoints` by averaging neighbours.
    public func points(window: TimeInterval, now: TimeInterval, maxPoints: Int = 600) -> [TimelinePoint] {
        let cutoff = now - window
        let recent = points.drop { $0.time < cutoff }
        guard recent.count > maxPoints else { return Array(recent) }
        let bucket = Int((Double(recent.count) / Double(maxPoints)).rounded(.up))
        var out: [TimelinePoint] = []
        var i = recent.startIndex
        while i < recent.endIndex {
            let slice = recent[i..<min(i + bucket, recent.endIndex)]
            let t = slice.map(\.time).reduce(0, +) / Double(slice.count)
            let v = slice.map(\.value).reduce(0, +) / Double(slice.count)
            out.append(TimelinePoint(time: t, value: v))
            i += bucket
        }
        return out
    }

    /// Median of the values within `window` seconds before `now`.
    public func median(window: TimeInterval, now: TimeInterval) -> Double? {
        let cutoff = now - window
        return TimedMedian.median(points.lazy.filter { $0.time >= cutoff }.map(\.value))
    }

    public var isEmpty: Bool { points.isEmpty && binValues.isEmpty }
    public var latestTime: TimeInterval? { points.last?.time }
}

import Foundation

/// A raw measured quantity.
public enum Metric: String, CaseIterable, Sendable, Codable, Hashable {
    case pitch, f1, f2, f3, vocalTractLength, h1h2, centroid, alphaRatio

    public var unit: String {
        switch self {
        case .pitch, .f1, .f2, .f3, .centroid: "Hz"
        case .vocalTractLength: "cm"
        case .h1h2, .alphaRatio: "dB"
        }
    }
}

/// A user-facing indicator, each built from one or more metrics.
public enum Indicator: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case pitch, formants, resonance, weight, brightness

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pitch: "Pitch"
        case .formants: "Formants"
        case .resonance: "Resonance"
        case .weight: "Weight"
        case .brightness: "Brightness"
        }
    }

    public var metrics: [Metric] {
        switch self {
        case .pitch: [.pitch]
        case .formants: [.f1, .f2, .f3]
        case .resonance: [.vocalTractLength]
        case .weight: [.h1h2]
        case .brightness: [.alphaRatio]
        }
    }
}

extension VoiceFrame {
    /// The frame's measurements keyed by metric; absent when unvoiced.
    public var metricValues: [Metric: Double] {
        var values: [Metric: Double] = [:]
        guard isVoiced else { return values }
        values[.pitch] = pitch
        if formants.count > 0 { values[.f1] = formants[0].frequency }
        if formants.count > 1 { values[.f2] = formants[1].frequency }
        if formants.count > 2 { values[.f3] = formants[2].frequency }
        values[.vocalTractLength] = vocalTractLength
        values[.h1h2] = h1h2
        values[.centroid] = centroid
        values[.alphaRatio] = alphaRatio
        return values
    }
}

/// Summary of a stretch of speech, used as the baseline to compare against.
public struct VoiceProfile: Sendable, Codable, Equatable {
    public var recordedAt: Date
    public var duration: TimeInterval
    public var medians: [Metric: Double]

    public init(recordedAt: Date = .now, duration: TimeInterval, medians: [Metric: Double]) {
        self.recordedAt = recordedAt
        self.duration = duration
        self.medians = medians
    }
}

/// Collects voiced frames while a baseline is being recorded.
public struct ProfileAccumulator: Sendable {
    public let startTime: TimeInterval
    public let duration: TimeInterval
    /// Seconds of voiced speech required for a usable profile.
    public let minimumVoiced: TimeInterval
    private var values: [Metric: [Double]] = [:]
    private var voicedFrames = 0
    private var frameHop: TimeInterval = 0.02

    public init(startTime: TimeInterval, duration: TimeInterval = 10, minimumVoiced: TimeInterval = 1) {
        self.startTime = startTime
        self.duration = duration
        self.minimumVoiced = minimumVoiced
    }

    public mutating func add(_ frame: VoiceFrame) {
        guard frame.isVoiced else { return }
        voicedFrames += 1
        for (metric, value) in frame.metricValues {
            values[metric, default: []].append(value)
        }
    }

    public func progress(at time: TimeInterval) -> Double {
        max(0, min(1, (time - startTime) / duration))
    }

    public var voicedDuration: TimeInterval { Double(voicedFrames) * frameHop }

    public func finish() -> VoiceProfile? {
        guard voicedDuration >= minimumVoiced else { return nil }
        var medians: [Metric: Double] = [:]
        for (metric, list) in values {
            if let median = TimedMedian.median(list) { medians[metric] = median }
        }
        return VoiceProfile(duration: duration, medians: medians)
    }
}

/// Live state derived from the frame stream: smoothed current values, per-metric
/// history, the baseline profile and drift. Owned by one actor or the main
/// thread; not internally synchronised.
public final class VoiceSession {
    public private(set) var smoothers: [Metric: TimedMedian] = [:]
    public private(set) var timelines: [Metric: Timeline] = [:]
    /// Smoothed values for the metrics that are currently measurable.
    public private(set) var current: [Metric: Double] = [:]
    public private(set) var lastFrame: VoiceFrame?
    public var baseline: VoiceProfile?
    public private(set) var recording: ProfileAccumulator?
    /// Time of the last voiced frame.
    public private(set) var lastVoicedTime: TimeInterval?

    public init(smoothingWindow: TimeInterval = 0.15, hold: TimeInterval = 0.3,
                timelineResolution: TimeInterval = 0.1, timelineCapacity: TimeInterval = 600) {
        for metric in Metric.allCases {
            smoothers[metric] = TimedMedian(window: smoothingWindow, hold: hold)
            timelines[metric] = Timeline(resolution: timelineResolution, capacity: timelineCapacity)
        }
    }

    public var now: TimeInterval { lastFrame?.time ?? 0 }

    public func ingest(_ frame: VoiceFrame) {
        lastFrame = frame
        if frame.isVoiced { lastVoicedTime = frame.time }
        let values = frame.metricValues
        for metric in Metric.allCases {
            let value = values[metric]
            if let smoothed = smoothers[metric]!.push(value, at: frame.time) {
                current[metric] = smoothed
            } else {
                current.removeValue(forKey: metric)
            }
            timelines[metric]!.append(value, at: frame.time)
        }
        if var accumulator = recording {
            accumulator.add(frame)
            if frame.time - accumulator.startTime >= accumulator.duration {
                if let profile = accumulator.finish() { baseline = profile }
                recording = nil
            } else {
                recording = accumulator
            }
        }
    }

    public func startBaselineRecording(duration: TimeInterval = 10) {
        recording = ProfileAccumulator(startTime: now, duration: duration)
    }

    public func cancelBaselineRecording() {
        recording = nil
    }

    /// Change in a metric: the median of the last `recent` seconds minus the
    /// median of the last `reference` seconds.
    public func drift(_ metric: Metric, recent: TimeInterval = 10, reference: TimeInterval = 600) -> Double? {
        guard let timeline = timelines[metric],
              let recentMedian = timeline.median(window: recent, now: now),
              let referenceMedian = timeline.median(window: reference, now: now) else { return nil }
        return recentMedian - referenceMedian
    }

    /// Recent median of a metric over `window` seconds.
    public func recentMedian(_ metric: Metric, window: TimeInterval = 2) -> Double? {
        timelines[metric]?.median(window: window, now: now)
    }

    /// Geometric-mean shift of F1 to F3 against the baseline, as a fraction
    /// (0.05 means formants sit 5 % higher than at baseline). Nil without a
    /// baseline or recent formants.
    public func formantShift(window: TimeInterval = 2) -> Double? {
        guard let baseline else { return nil }
        var logRatios: [Double] = []
        for metric in [Metric.f1, .f2, .f3] {
            guard let base = baseline.medians[metric], base > 0,
                  let recent = recentMedian(metric, window: window) else { continue }
            logRatios.append(log(recent / base))
        }
        guard !logRatios.isEmpty else { return nil }
        return exp(logRatios.reduce(0, +) / Double(logRatios.count)) - 1
    }
}

import AVFoundation
import Foundation
import Observation
import VoiceAnalysis
import os

private let log = Logger(subsystem: "com.zoezyla.voice", category: "monitor")

/// Owns the analyzer and runs it off the main actor. When idle it only checks
/// the input level, and wakes itself on the first loud enough chunk.
actor AnalysisEngine {
    private let analyzer = VoiceAnalyzer()
    private var idle = false
    private let gate = Float(AnalyzerConfiguration().levelGateDb)

    func process(_ samples: [Float]) -> [VoiceFrame] {
        if idle {
            guard Signal.decibels(Signal.rms(samples)) >= gate else { return [] }
            idle = false
        }
        return analyzer.process(samples)
    }

    func setIdle(_ value: Bool) { idle = value }
}

/// Main-actor model behind the menu bar item and the panel: capture state,
/// smoothed values refreshed at the display rate, baseline and targets.
@Observable
final class VoiceMonitor {
    enum State: Equatable {
        case stopped, requestingPermission, denied, listening, idle, paused
        case failed(String)

        var title: String {
            switch self {
            case .stopped: "Stopped"
            case .requestingPermission: "Waiting for microphone access"
            case .denied: "Microphone access denied"
            case .listening: "Listening"
            case .idle: "Idle, will resume on speech"
            case .paused: "Paused"
            case .failed(let message): message
            }
        }
    }

    static let displayRate = 15.0
    static let baselineDuration: TimeInterval = 10

    let settings: AppSettings
    let session = VoiceSession()
    private(set) var state: State = .stopped {
        didSet { if state != oldValue { log.info("State: \(self.state.title, privacy: .public)") } }
    }
    private(set) var level: Double = -120
    private(set) var isVoiced = false
    private(set) var current: [Metric: Double] = [:]
    private(set) var now: TimeInterval = 0
    private(set) var baselineProgress: Double?
    /// Input devices currently attached, refreshed when the system reports a change.
    private(set) var inputDevices: [AudioInputDevice] = []
    /// Name of the device being captured, for the panel.
    private(set) var activeInputName: String?

    private let engine = AnalysisEngine()
    @ObservationIgnored private var capture: AudioCapture?
    @ObservationIgnored private var displayTask: Task<Void, Never>?
    @ObservationIgnored private var lastSpeech = Date()
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var deviceObserver: AudioDevices.ChangeToken?

    init(settings: AppSettings) {
        self.settings = settings
        session.baseline = settings.baseline
        inputDevices = AudioDevices.inputDevices()
        log.info("Input devices: \(self.inputDevices.map(\.name).joined(separator: ", "), privacy: .public)")
        deviceObserver = AudioDevices.observeChanges { [weak self] in
            Task { @MainActor in self?.devicesChanged() }
        }
    }

    // MARK: Input devices

    private func devicesChanged() {
        inputDevices = AudioDevices.inputDevices()
        let names = inputDevices.map(\.name).joined(separator: ", ")
        log.info("Input devices: \(names, privacy: .public)")
        // The engine restarts itself on configuration changes; just refresh the label.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            self.activeInputName = self.capture?.activeDeviceName
        }
    }

    /// Selects an input by device UID, or nil for the system default.
    func selectInput(uid: String?) {
        settings.inputDeviceUID = uid
        capture?.setPreferredDevice(uid: uid)
        activeInputName = capture?.activeDeviceName
    }

    /// True when the chosen device is not attached and the default is in use.
    var isUsingFallbackInput: Bool { capture?.isUsingFallback ?? false }

    // MARK: Lifecycle

    func start() async {
        switch AudioCapture.authorizationStatus {
        case .authorized:
            break
        case .notDetermined:
            state = .requestingPermission
            guard await AudioCapture.requestPermission() else { state = .denied; return }
        default:
            state = .denied
            return
        }
        startCapture()
    }

    private func startCapture() {
        let engine = self.engine
        let capture = AudioCapture { [weak self] samples in
            Task {
                let frames = await engine.process(samples)
                guard !frames.isEmpty else { return }
                await self?.enqueue(frames)
            }
        }
        capture.setPreferredDevice(uid: settings.inputDeviceUID)
        do {
            try capture.start()
            self.capture = capture
            activeInputName = capture.activeDeviceName
            state = .listening
            lastSpeech = .now
            startDisplayLoop()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func pause() {
        capture?.stop()
        capture = nil
        displayTask?.cancel()
        displayTask = nil
        state = .paused
        current = [:]
        isVoiced = false
    }

    func resume() {
        guard state == .paused || state == .stopped else { return }
        startCapture()
    }

    var isPaused: Bool { state == .paused }

    // MARK: Frames

    private func enqueue(_ frames: [VoiceFrame]) {
        for frame in frames { session.ingest(frame) }
        if frames.contains(where: \.isVoiced) {
            lastSpeech = .now
            if state == .idle { state = .listening }
        }
    }

    private func startDisplayLoop() {
        displayTask?.cancel()
        displayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int(1000 / VoiceMonitor.displayRate)))
                self?.refreshDisplay()
            }
        }
    }

    private func refreshDisplay() {
        current = session.current
        now = session.now
        ticks += 1
        if ticks % Int(VoiceMonitor.displayRate * 5) == 0 { logSummary() }
        if let frame = session.lastFrame {
            level = frame.level
            isVoiced = frame.isVoiced && !session.current.isEmpty
        }
        if let recording = session.recording {
            baselineProgress = recording.progress(at: now)
        } else if baselineProgress != nil {
            baselineProgress = nil
            settings.baseline = session.baseline
        }
        if settings.autoIdleEnabled, state == .listening,
           Date.now.timeIntervalSince(lastSpeech) > Double(settings.autoIdleMinutes) * 60 {
            state = .idle
            Task { await engine.setIdle(true) }
        }
    }

    /// Five-second summary in the system log, so the pipeline can be checked
    /// without looking at the screen. Numbers only, never audio.
    private func logSummary() {
        let voiced = session.recentMedian(.pitch, window: 5) != nil
        guard voiced else {
            log.debug("Last 5 s: no voiced speech (level \(Int(self.level)) dB)")
            return
        }
        func m(_ metric: Metric) -> String {
            session.recentMedian(metric, window: 5).map { String(format: "%.1f", $0) } ?? "–"
        }
        let text = "pitch \(m(.pitch)) Hz, F1-3 \(m(.f1))/\(m(.f2))/\(m(.f3)) Hz, VTL \(m(.vocalTractLength)) cm, H1-H2 \(m(.h1h2)) dB, alpha \(m(.alphaRatio)) dB"
        log.info("Last 5 s medians: \(text, privacy: .public)")
    }

    // MARK: Baseline

    var isRecordingBaseline: Bool { baselineProgress != nil }

    func recordBaseline() {
        guard state == .listening || state == .idle else { return }
        session.startBaselineRecording(duration: VoiceMonitor.baselineDuration)
        baselineProgress = 0
    }

    func cancelBaseline() {
        session.cancelBaselineRecording()
        baselineProgress = nil
    }

    func clearBaseline() {
        session.baseline = nil
        settings.baseline = nil
    }

    var baseline: VoiceProfile? { session.baseline }

    // MARK: Derived readouts

    /// 0 to 100 gauge for resonance and weight; nil for other indicators or when unmeasured.
    func gauge(for indicator: Indicator) -> Double? {
        switch indicator {
        case .resonance: current[.vocalTractLength].map(settings.calibration.resonanceGauge)
        case .weight: current[.h1h2].map(settings.calibration.weightGauge)
        default: nil
        }
    }

    /// Target band for an indicator in that indicator's display units.
    func targetRange(for indicator: Indicator) -> ClosedRange<Double>? {
        switch indicator {
        case .pitch: settings.pitchRange
        case .resonance: settings.preset.resonanceRange
        case .weight: settings.preset.weightRange
        default: nil
        }
    }

    /// Whether the current value sits inside the target band; nil when there is no band or value.
    func isInRange(_ indicator: Indicator) -> Bool? {
        guard let range = targetRange(for: indicator) else { return nil }
        switch indicator {
        case .pitch: return current[.pitch].map(range.contains)
        default: return gauge(for: indicator).map(range.contains)
        }
    }

    /// Change in the last ten seconds against the session, for the primary metric.
    func drift(for indicator: Indicator) -> Double? {
        guard let metric = indicator.metrics.first else { return nil }
        return session.drift(metric, recent: 10, reference: 600)
    }

    /// Fractional formant shift against the baseline (0.05 is 5 % higher).
    var formantShift: Double? { session.formantShift() }

    /// Brightness relative to the baseline in dB.
    var brightnessTrend: Double? {
        guard let base = baseline?.medians[.alphaRatio], let now = current[.alphaRatio] else { return nil }
        return now - base
    }

    func timelinePoints(_ metric: Metric) -> [TimelinePoint] {
        session.timelines[metric]?.points(window: settings.chartWindow.rawValue, now: now, maxPoints: 400) ?? []
    }
}

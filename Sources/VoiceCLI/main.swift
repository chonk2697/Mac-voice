import AVFoundation
import Foundation
import VoiceAnalysis

// voice-cli: run the same analysis the app uses over a WAV file, record a
// clip for offline analysis, or synthesize a test vowel. No dependencies
// beyond Apple frameworks.
//
//   voice-cli analyze <file.wav> [--json | --frames]
//   voice-cli record <out.wav> [--seconds 20]
//   voice-cli synth <out.wav> [--f0 180] [--vowel feminineAh] [--tilt 12] [--seconds 2]

let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String, default value: String) -> String {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return value }
    return arguments[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Reads any audio file AVFoundation understands as 16 kHz mono float samples.
func loadMono16k(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
        fail("Cannot convert \(file.processingFormat) to 16 kHz mono")
    }
    let frameCount = AVAudioFrameCount(file.length)
    guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
        fail("Empty file")
    }
    try file.read(into: input)
    let ratio = target.sampleRate / file.processingFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { fail("Allocation failed") }
    var consumed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if consumed {
            status.pointee = .endOfStream
            return nil
        }
        consumed = true
        status.pointee = .haveData
        return input
    }
    if let error { throw error }
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}

/// Writes mono samples as a 16-bit PCM WAV, the most widely readable form
/// (Praat, Python audio libraries and QuickTime all open it).
func writeWav(_ samples: [Float], sampleRate: Double, to url: URL) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

func format(_ value: Double?, _ digits: Int = 0) -> String {
    guard let value else { return "—" }
    return String(format: "%.\(digits)f", value)
}

func analyze() throws {
    guard arguments.count >= 2 else { fail("usage: voice-cli analyze <file.wav> [--json | --frames]") }
    let url = URL(fileURLWithPath: arguments[1])
    let samples = try loadMono16k(url)
    let analyzer = VoiceAnalyzer()
    let session = VoiceSession()
    let calibration = Calibration()
    var frames: [VoiceFrame] = []
    for start in stride(from: 0, to: samples.count, by: 1024) {
        let chunk = Array(samples[start..<min(start + 1024, samples.count)])
        for frame in analyzer.process(chunk) {
            session.ingest(frame)
            frames.append(frame)
        }
    }
    frames += analyzer.flush()
    let voiced = frames.filter(\.isVoiced)
    let json = arguments.contains("--json")

    // Every analysis hop as one JSON object per line, for comparison against
    // other tools. Times are the centre of the formant analysis window.
    if arguments.contains("--frames") {
        for frame in frames {
            var object: [String: Any] = [
                "time": ((frame.time - analyzer.formantWindowDelay) * 1000).rounded() / 1000,
                "voiced": frame.isVoiced,
                "formants": frame.formants.map { [($0.frequency * 10).rounded() / 10, ($0.bandwidth * 10).rounded() / 10] },
            ]
            object["pitch"] = frame.pitch.map { ($0 * 10).rounded() / 10 } ?? NSNull()
            object["vtl"] = frame.vocalTractLength.map { ($0 * 100).rounded() / 100 } ?? NSNull()
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        }
        return
    }

    func median(_ metric: Metric) -> Double? {
        TimedMedian.median(voiced.compactMap { $0.metricValues[metric] })
    }
    let summary: [(String, Double?)] = [
        ("pitch_hz", median(.pitch)),
        ("f1_hz", median(.f1)), ("f2_hz", median(.f2)), ("f3_hz", median(.f3)),
        ("vocal_tract_cm", median(.vocalTractLength)),
        ("resonance_gauge", median(.vocalTractLength).map(calibration.resonanceGauge)),
        ("h1h2_db", median(.h1h2)),
        ("weight_gauge", median(.h1h2).map(calibration.weightGauge)),
        ("alpha_ratio_db", median(.alphaRatio)),
        ("centroid_hz", median(.centroid)),
    ]

    if json {
        var object: [String: Any] = [
            "file": url.lastPathComponent,
            "seconds": Double(samples.count) / 16_000,
            "voiced_fraction": frames.isEmpty ? 0 : Double(voiced.count) / Double(frames.count),
        ]
        for (key, value) in summary { object[key] = value ?? NSNull() }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        return
    }

    print("\(url.lastPathComponent): \(format(Double(samples.count) / 16_000, 1)) s, "
          + "\(voiced.count) of \(frames.count) frames voiced")
    print("medians over voiced speech:")
    for (key, value) in summary {
        print("  \(key.padding(toLength: 16, withPad: " ", startingAt: 0)) \(format(value, key.hasSuffix("cm") || key.hasSuffix("db") ? 1 : 0))")
    }
    print("per second (pitch / F1 F2 F3 / H1-H2 / alpha ratio):")
    var second = 0
    while Double(second) < Double(samples.count) / 16_000 {
        let slice = voiced.filter { Int($0.time) == second }
        func m(_ metric: Metric) -> Double? { TimedMedian.median(slice.compactMap { $0.metricValues[metric] }) }
        print("  \(String(format: "%3d", second))s  \(format(m(.pitch))) Hz  "
              + "\(format(m(.f1))) \(format(m(.f2))) \(format(m(.f3)))  "
              + "\(format(m(.h1h2), 1)) dB  \(format(m(.alphaRatio), 1)) dB")
        second += 1
    }
}

/// Captures the default microphone as 16 kHz mono, the same conversion the
/// app does, and keeps the samples in memory until stopped.
final class Recorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var recentPeak: Float = 0
    private(set) var inputDescription = ""

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            fail("No microphone input is available.")
        }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            fail("The microphone format \(inputFormat) cannot be converted to 16 kHz mono.")
        }
        inputDescription = "\(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch"
        let ratio = target.sampleRate / inputFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, output.frameLength > 0, let channel = output.floatChannelData else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
            lock.withLock {
                samples += chunk
                recentPeak = max(recentPeak, chunk.map(abs).max() ?? 0)
            }
        }
        engine.prepare()
        try engine.start()
    }

    /// Peak level since the last call, in dBFS.
    func takePeakDb() -> Double {
        lock.withLock {
            let peak = recentPeak
            recentPeak = 0
            return Double(Signal.decibels(peak))
        }
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock { samples }
    }
}

func record() throws {
    guard arguments.count >= 2 else { fail("usage: voice-cli record <out.wav> [--seconds 20]") }
    let url = URL(fileURLWithPath: arguments[1])
    let seconds = Double(option("seconds", default: "20")) ?? 20
    guard seconds > 0 else { fail("--seconds must be positive") }

    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        break
    case .notDetermined:
        let granted = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var allowed = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            allowed = ok
            granted.signal()
        }
        granted.wait()
        guard allowed else { fail("Microphone access was not granted.") }
    default:
        fail("Microphone access is denied. Allow it for your terminal in System Settings > Privacy & Security > Microphone.")
    }

    let recorder = Recorder()
    try recorder.start()
    print("Recording \(format(seconds, 0)) s to \(url.lastPathComponent) (\(recorder.inputDescription), saved as 16 kHz mono). Speak normally.")
    let start = Date()
    var lastTick = -1
    while true {
        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= seconds { break }
        Thread.sleep(forTimeInterval: 0.1)
        let tick = Int(elapsed)
        if tick != lastTick {
            lastTick = tick
            let peak = recorder.takePeakDb()
            let bars = max(0, min(20, Int((peak + 60) / 3)))
            let meter = String(repeating: "#", count: bars) + String(repeating: ".", count: 20 - bars)
            print("  \(String(format: "%2d", Int(seconds) - tick)) s left  [\(meter)] \(format(peak, 0)) dBFS")
        }
    }
    let samples = recorder.stop()
    guard !samples.isEmpty else { fail("No audio was captured.") }
    try writeWav(samples, sampleRate: 16_000, to: url)
    let peak = Double(Signal.decibels(samples.map(abs).max() ?? 0))
    print("wrote \(url.path): \(format(Double(samples.count) / 16_000, 1)) s, peak \(format(peak, 0)) dBFS")
    if peak < -30 { print("warning: the recording is quiet; check the input device and level") }
}

/// Raw LPC candidates per frame, on a fixed grid, for comparing the front
/// end against other tools. Settings default to the analyzer's; any can be
/// overridden to experiment.
func candidates() throws {
    guard arguments.count >= 2 else { fail("usage: voice-cli candidates <file.wav> [--window 0.03] [--sigma 0.1667] [--order 10] [--pre 2] [--maxbw 500] [--up 2 --down 3] [--hop 0.01] [--start 0.025] [--highpass 75]") }
    var samples = try loadMono16k(URL(fileURLWithPath: arguments[1]))
    let highPassHz = Double(option("highpass", default: "75")) ?? 75
    if highPassHz > 0 {
        var filter = HighPassFilter(sampleRate: 16_000, cutoff: highPassHz)
        samples = filter.process(samples)
    }
    let estimator = FormantEstimator(
        sampleRate: 16_000,
        order: Int(option("order", default: "10")) ?? 10,
        windowDuration: Double(option("window", default: "0.03")) ?? 0.03,
        resampleUp: Int(option("up", default: "2")) ?? 2, resampleDown: Int(option("down", default: "3")) ?? 3,
        preEmphasisBeforeResampling: option("pre", default: "2") == "2",
        minFormantFrequency: 50,
        maxBandwidth: Double(option("maxbw", default: "500")) ?? 500,
        windowSigmaFraction: option("sigma", default: "0.1667") == "praat"
            ? Window.praatSigmaFraction : (Double(option("sigma", default: "0.1667")) ?? 1.0 / 6))
    let hop = Double(option("hop", default: "0.01")) ?? 0.01
    var time = Double(option("start", default: "0.025")) ?? 0.025
    let needed = estimator.requiredSamples
    while true {
        let end = Int(((time + estimator.windowCentreDelay) * 16_000).rounded())
        if end > samples.count { break }
        if end >= needed {
            let found = estimator.candidates(Array(samples[(end - needed)..<end]))
            let object: [String: Any] = [
                "time": (time * 1000).rounded() / 1000,
                "candidates": found.map { [($0.frequency * 10).rounded() / 10, ($0.bandwidth * 10).rounded() / 10] },
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
        }
        time += hop
    }
}

func synth() throws {
    guard arguments.count >= 2 else { fail("usage: voice-cli synth <out.wav> [--f0 180] [--vowel feminineAh | --formants f:bw,...] [--tilt 12] [--seconds 2]") }
    let vowels: [String: [VowelSynthesizer.Formant]] = [
        "masculineAh": VowelSynthesizer.masculineAh, "masculineEe": VowelSynthesizer.masculineEe,
        "feminineAh": VowelSynthesizer.feminineAh, "feminineEe": VowelSynthesizer.feminineEe,
    ]
    var vowelName = option("vowel", default: "feminineAh")
    var formants = vowels[vowelName]
    // --formants 650:220,1500:120,2500:200 gives explicit frequency:bandwidth pairs.
    let explicit = option("formants", default: "")
    if !explicit.isEmpty {
        formants = explicit.split(separator: ",").compactMap { pair -> VowelSynthesizer.Formant? in
            let parts = pair.split(separator: ":").compactMap { Double($0) }
            return parts.count == 2 ? VowelSynthesizer.Formant(parts[0], bandwidth: parts[1]) : nil
        }
        vowelName = explicit
    }
    guard let formants, !formants.isEmpty else { fail("unknown vowel; choose from \(vowels.keys.sorted()) or give --formants f:bw,...") }
    let synth = VowelSynthesizer(f0: Double(option("f0", default: "180")) ?? 180, formants: formants,
                                 sourceTiltDbPerOctave: Double(option("tilt", default: "12")) ?? 12)
    let samples = synth.render(duration: Double(option("seconds", default: "2")) ?? 2)
    try writeWav(samples, sampleRate: 16_000, to: URL(fileURLWithPath: arguments[1]))
    print("wrote \(arguments[1]): \(vowelName) at \(synth.f0) Hz, tilt \(synth.sourceTiltDbPerOctave) dB/oct")
}

/// Lists microphones as AVCaptureDevice sees them, with the identifiers the app saves.
func devices() {
    let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
    let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
    for device in discovery.devices {
        let mark = device.uniqueID == defaultID ? " (system default)" : ""
        print("\(device.localizedName)\(mark)\n    id: \(device.uniqueID)\n    model: \(device.modelID)")
    }
}

do {
    switch arguments.first {
    case "devices": devices()
    case "analyze": try analyze()
    case "record": try record()
    case "candidates": try candidates()
    case "synth": try synth()
    default: fail("usage: voice-cli analyze <file.wav> [--json | --frames] | record <out.wav> [--seconds N] | synth <out.wav> [--f0 N] [--vowel NAME] [--tilt N] [--seconds N]")
    }
} catch {
    fail("error: \(error)")
}

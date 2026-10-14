import AVFoundation
import Foundation
import VoiceAnalysis

// voice-cli: run the same analysis the app uses over a WAV file, or synthesize
// a test vowel. No dependencies beyond Apple frameworks.
//
//   voice-cli analyze <file.wav> [--json]
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

func writeWav(_ samples: [Float], sampleRate: Double, to url: URL) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

func format(_ value: Double?, _ digits: Int = 0) -> String {
    guard let value else { return "—" }
    return String(format: "%.\(digits)f", value)
}

func analyze() throws {
    guard arguments.count >= 2 else { fail("usage: voice-cli analyze <file.wav> [--json]") }
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
    let voiced = frames.filter(\.isVoiced)
    let json = arguments.contains("--json")

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

func synth() throws {
    guard arguments.count >= 2 else { fail("usage: voice-cli synth <out.wav> [--f0 180] [--vowel feminineAh] [--tilt 12] [--seconds 2]") }
    let vowels: [String: [VowelSynthesizer.Formant]] = [
        "masculineAh": VowelSynthesizer.masculineAh, "masculineEe": VowelSynthesizer.masculineEe,
        "feminineAh": VowelSynthesizer.feminineAh, "feminineEe": VowelSynthesizer.feminineEe,
    ]
    let vowelName = option("vowel", default: "feminineAh")
    guard let formants = vowels[vowelName] else { fail("unknown vowel; choose from \(vowels.keys.sorted())") }
    let synth = VowelSynthesizer(f0: Double(option("f0", default: "180")) ?? 180, formants: formants,
                                 sourceTiltDbPerOctave: Double(option("tilt", default: "12")) ?? 12)
    let samples = synth.render(duration: Double(option("seconds", default: "2")) ?? 2)
    try writeWav(samples, sampleRate: 16_000, to: URL(fileURLWithPath: arguments[1]))
    print("wrote \(arguments[1]): \(vowelName) at \(synth.f0) Hz, tilt \(synth.sourceTiltDbPerOctave) dB/oct")
}

do {
    switch arguments.first {
    case "analyze": try analyze()
    case "synth": try synth()
    default: fail("usage: voice-cli analyze <file.wav> [--json] | synth <out.wav> [--f0 N] [--vowel NAME] [--tilt N] [--seconds N]")
    }
} catch {
    fail("error: \(error)")
}

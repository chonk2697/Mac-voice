import AVFoundation
import Foundation
import os

nonisolated private let log = Logger(subsystem: "com.zoezyla.voice", category: "capture")

/// Captures the default microphone and delivers 16 kHz mono float chunks on
/// an audio thread. Restarts itself when the input device changes.
nonisolated final class AudioCapture: @unchecked Sendable {
    typealias Handler = @Sendable ([Float]) -> Void

    static let sampleRate = 16_000.0

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: AudioCapture.sampleRate,
                                             channels: 1, interleaved: false)!
    private let handler: Handler
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var running = false
    private var observer: (any NSObjectProtocol)?

    init(handler: @escaping Handler) {
        self.handler = handler
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // The input format may have changed (new device); rebuild the tap.
            guard let self else { return }
            log.info("Audio configuration changed; restarting capture")
            DispatchQueue.global(qos: .userInitiated).async { self.restart() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Name of the current default input device, for display.
    var inputDeviceName: String {
        lock.withLock {
            let format = engine.inputNode.inputFormat(forBus: 0)
            return "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch"
        }
    }

    func start() throws {
        try lock.withLock {
            guard !running else { return }
            try installTapAndStart()
            running = true
        }
    }

    func stop() {
        lock.withLock {
            guard running else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            running = false
        }
    }

    private func restart() {
        lock.withLock {
            guard running else { return }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            do {
                try installTapAndStart()
            } catch {
                running = false
            }
        }
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInput
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.unsupportedFormat
        }
        self.converter = converter
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let target = targetFormat
        let handler = self.handler

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
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
            handler(Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength))))
        }
        engine.prepare()
        try engine.start()
        log.info("Capturing \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch, converting to 16 kHz mono")
    }

    enum CaptureError: Error, LocalizedError {
        case noInput, unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .noInput: "No microphone input is available."
            case .unsupportedFormat: "The microphone format cannot be converted."
            }
        }
    }
}

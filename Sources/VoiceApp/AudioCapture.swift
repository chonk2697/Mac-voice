import AVFoundation
import CoreAudio
import Foundation
import os

nonisolated private let log = Logger(subsystem: "com.zoezyla.voice", category: "capture")

/// Captures a microphone and delivers 16 kHz mono float chunks on an audio
/// thread. The input can be the system default or a specific device by UID;
/// capture restarts itself when the device configuration changes.
nonisolated final class AudioCapture: @unchecked Sendable {
    typealias Handler = @Sendable ([Float]) -> Void

    static let sampleRate = 16_000.0

    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: AudioCapture.sampleRate,
                                             channels: 1, interleaved: false)!
    private let handler: Handler
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var observer: (any NSObjectProtocol)?
    private var running = false
    private var preferredDeviceUID: String?
    private var activeDeviceID: AudioDeviceID?

    init(handler: @escaping Handler) {
        self.handler = handler
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

    /// Name of the device actually being captured, for display.
    var activeDeviceName: String? {
        lock.withLock { activeDeviceID.flatMap(AudioDevices.name(of:)) }
    }

    /// True when a preferred device was requested but is not available, so
    /// the system default is in use instead.
    var isUsingFallback: Bool {
        lock.withLock { preferredDeviceUID != nil && activeDeviceID == AudioDevices.defaultInputDeviceID() && AudioDevices.device(uid: preferredDeviceUID!) == nil }
    }

    /// Chooses the input by device UID, or nil for the system default.
    /// Restarts capture if it is running.
    func setPreferredDevice(uid: String?) {
        lock.withLock {
            preferredDeviceUID = uid
            guard running else { return }
            tearDown()
            do {
                try setUp()
            } catch {
                running = false
                log.error("Restart on device change failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func start() throws {
        try lock.withLock {
            guard !running else { return }
            try setUp()
            running = true
        }
    }

    func stop() {
        lock.withLock {
            guard running else { return }
            tearDown()
            running = false
        }
    }

    private func restart() {
        lock.withLock {
            guard running else { return }
            tearDown()
            do {
                try setUp()
            } catch {
                running = false
                log.error("Restart failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        activeDeviceID = nil
    }

    /// Builds a fresh engine each time so that the input node picks up the
    /// chosen device's format cleanly.
    private func setUp() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        var selected: AudioDeviceID? = nil
        if let uid = preferredDeviceUID {
            if let device = AudioDevices.device(uid: uid) {
                selected = device.id
            } else {
                log.notice("Preferred input \(uid, privacy: .public) not present; using the system default")
            }
        }
        if let deviceID = selected, let unit = input.audioUnit {
            var id = deviceID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                log.error("Could not select input device (\(status)); using the system default")
                selected = nil
            }
        }
        activeDeviceID = selected ?? AudioDevices.defaultInputDeviceID()

        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.noInput
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.unsupportedFormat
        }
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

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            log.info("Audio configuration changed; restarting capture")
            DispatchQueue.global(qos: .userInitiated).async { self.restart() }
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        let name = activeDeviceID.flatMap(AudioDevices.name(of:)) ?? "unknown device"
        log.info("Capturing \(name, privacy: .public): \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch, converting to 16 kHz mono")
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

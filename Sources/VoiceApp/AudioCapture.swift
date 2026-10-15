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
    /// Serialises reactions to configuration changes so they cannot pile up.
    private let changeQueue = DispatchQueue(label: "com.zoezyla.voice.capture")
    private var recentRestarts: [Date] = []
    /// More restarts than this within `restartWindow` means something is looping.
    private let maxRestarts = 4
    private let restartWindow: TimeInterval = 3

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

    /// False once capture has stopped on its own, for example after looping restarts.
    var isRunning: Bool {
        lock.withLock { running }
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

    /// AVAudioEngine stops itself when its input configuration changes, which
    /// also happens once right after we bind it to a non-default device. The
    /// same engine is restarted with a fresh tap; only if that fails (device
    /// unplugged) is everything rebuilt, which also resolves the fallback.
    private func handleConfigurationChange() {
        lock.withLock {
            guard running, let engine else { return }
            let now = Date.now
            recentRestarts = recentRestarts.filter { now.timeIntervalSince($0) < restartWindow }
            recentRestarts.append(now)
            guard recentRestarts.count <= maxRestarts else {
                log.error("Capture restarted \(self.recentRestarts.count) times in \(Int(self.restartWindow)) s; stopping")
                tearDown()
                running = false
                return
            }

            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            let format = engine.inputNode.inputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 {
                do {
                    try installTap(on: engine, format: format)
                    try engine.start()
                    activeDeviceID = AudioCapture.currentDevice(of: engine) ?? activeDeviceID
                    let name = activeDeviceID.flatMap(AudioDevices.name(of:)) ?? "unknown device"
                    log.info("Capture resumed on \(name, privacy: .public): \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
                    return
                } catch {
                    log.notice("Resume failed (\(error.localizedDescription, privacy: .public)); rebuilding capture")
                }
            } else {
                log.notice("Input format is empty after the change; rebuilding capture")
            }
            tearDown()
            do {
                try setUp()
            } catch {
                running = false
                log.error("Rebuild failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func currentDevice(of engine: AVAudioEngine) -> AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        return status == noErr && id != 0 ? id : nil
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
        try installTap(on: engine, format: inputFormat)

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            log.info("Audio configuration changed")
            changeQueue.async { self.handleConfigurationChange() }
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        let name = activeDeviceID.flatMap(AudioDevices.name(of:)) ?? "unknown device"
        log.info("Capturing \(name, privacy: .public): \(Int(inputFormat.sampleRate)) Hz, \(inputFormat.channelCount) ch, converting to 16 kHz mono")
    }

    private func installTap(on engine: AVAudioEngine, format inputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.unsupportedFormat
        }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let target = targetFormat
        let handler = self.handler

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
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

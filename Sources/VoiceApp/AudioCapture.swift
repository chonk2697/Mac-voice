import AVFoundation
import CoreMedia
import Foundation
import os

nonisolated private let log = Logger(subsystem: "com.zoezyla.voice", category: "capture")

/// Captures one microphone through AVCaptureSession and delivers 16 kHz mono
/// float chunks on a capture queue.
///
/// AVCaptureSession binds to a specific device and keeps that binding while
/// other apps open and close devices, which AVAudioEngine's input node does
/// not. The input can be a device by unique ID or the system default; a
/// chosen device that disappears falls back to the default until it returns.
nonisolated final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    typealias Handler = @Sendable ([Float]) -> Void

    static let sampleRate = 16_000.0

    private let handler: Handler
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.zoezyla.voice.capture")
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: AudioCapture.sampleRate,
                                             channels: 1, interleaved: false)!
    private var input: AVCaptureDeviceInput?
    private var activeDevice: AVCaptureDevice?
    private var preferredDeviceUID: String?
    private var running = false
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var observers: [any NSObjectProtocol] = []

    init(handler: @escaping Handler) {
        self.handler = handler
        super.init()
        output.setSampleBufferDelegate(self, queue: queue)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let device = note.object as? AVCaptureDevice else { return }
            self.deviceChanged(device, connected: false)
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let device = note.object as? AVCaptureDevice else { return }
            self.deviceChanged(device, connected: true)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            log.error("Capture session error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            self.queue.async { self.recover() }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: State for the UI

    /// Name of the device being captured.
    var activeDeviceName: String? {
        lock.withLock { activeDevice?.localizedName }
    }

    /// Same as `activeDeviceName`; kept for the diagnostics log.
    var liveDeviceName: String? { activeDeviceName }

    /// False once capture has stopped on its own.
    var isRunning: Bool {
        lock.withLock { running && session.isRunning }
    }

    var isFollowingDefault: Bool {
        lock.withLock { preferredDeviceUID == nil }
    }

    /// True when a device was chosen but is not attached, so the default is in use.
    var isUsingFallback: Bool {
        lock.withLock { preferredDeviceUID != nil && activeDevice?.uniqueID != preferredDeviceUID }
    }

    // MARK: Control

    /// Chooses the input by unique ID, or nil for the system default.
    func setPreferredDevice(uid: String?) {
        lock.withLock {
            preferredDeviceUID = uid
            guard running else { return }
            reconfigure(reason: "input changed")
        }
    }

    /// Call when the system default input changes; only matters when following it.
    func systemDefaultChanged() {
        lock.withLock {
            guard running, preferredDeviceUID == nil else { return }
            reconfigure(reason: "system default changed")
        }
    }

    func start() throws {
        try lock.withLock {
            guard !running else { return }
            try configure()
            session.startRunning()
            running = true
            log.info("Capturing \(self.activeDevice?.localizedName ?? "unknown", privacy: .public)")
        }
    }

    func stop() {
        lock.withLock {
            guard running else { return }
            session.stopRunning()
            running = false
        }
    }

    // MARK: Session configuration

    private func resolveDevice() -> AVCaptureDevice? {
        if let uid = preferredDeviceUID {
            if let device = AVCaptureDevice(uniqueID: uid) { return device }
            log.notice("Chosen input \(uid, privacy: .public) is not attached; using the system default")
        }
        return AVCaptureDevice.default(for: .audio)
    }

    /// Swaps the session's input for the resolved device. Works while running.
    private func configure() throws {
        guard let device = resolveDevice() else { throw CaptureError.noInput }
        if device.uniqueID == activeDevice?.uniqueID, input != nil, session.outputs.contains(output) { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let input {
            session.removeInput(input)
            self.input = nil
        }
        let newInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(newInput) else { throw CaptureError.noInput }
        session.addInput(newInput)
        input = newInput
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else { throw CaptureError.unsupportedFormat }
            session.addOutput(output)
        }
        activeDevice = device
        converter = nil
        converterInputFormat = nil
    }

    private func reconfigure(reason: String) {
        do {
            try configure()
            log.info("Now capturing \(self.activeDevice?.localizedName ?? "unknown", privacy: .public) (\(reason, privacy: .public))")
        } catch {
            log.error("Could not reconfigure capture (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deviceChanged(_ device: AVCaptureDevice, connected: Bool) {
        lock.withLock {
            guard running else { return }
            if !connected, device.uniqueID == activeDevice?.uniqueID {
                reconfigure(reason: "\(device.localizedName) disconnected")
            } else if connected, device.uniqueID == preferredDeviceUID, activeDevice?.uniqueID != preferredDeviceUID {
                reconfigure(reason: "\(device.localizedName) reconnected")
            }
        }
    }

    private func recover() {
        lock.withLock {
            guard running else { return }
            if !session.isRunning {
                reconfigure(reason: "recovering from error")
                session.startRunning()
            }
        }
    }

    // MARK: Sample delivery

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let description = sampleBuffer.formatDescription else { return }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)

        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard sizeNeeded > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr, let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: list) else { return }
        withExtendedLifetime(block) {
            if let samples = convert(pcm, from: inputFormat), !samples.isEmpty {
                handler(samples)
            }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, from inputFormat: AVAudioFormat) -> [Float]? {
        if inputFormat.sampleRate == targetFormat.sampleRate, inputFormat.channelCount == 1,
           inputFormat.commonFormat == .pcmFormatFloat32, let channel = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }
        if converter == nil || converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            converterInputFormat = inputFormat
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    enum CaptureError: Error, LocalizedError {
        case noInput, unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .noInput: "No microphone input is available."
            case .unsupportedFormat: "The microphone format cannot be used."
            }
        }
    }
}

import CoreAudio
import Foundation

/// An audio device that has at least one input channel.
nonisolated struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    /// Stable identifier that survives relaunches and replugging.
    let uid: String
    let name: String
}

/// Core Audio queries for input devices, plus change notifications.
nonisolated enum AudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> String? {
        var addr = address(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, pointer)
        }
        return status == noErr ? value as String : nil
    }

    private static func inputChannelCount(of device: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Every device with input channels, in Core Audio's order.
    static func inputDevices() -> [AudioInputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(of: id) > 0,
                  let uid = string(kAudioDevicePropertyDeviceUID, of: id),
                  let name = string(kAudioObjectPropertyName, of: id),
                  // Core Audio's private aggregate that stands in for the default device.
                  !uid.hasPrefix("CADefaultDeviceAggregate"), !name.hasPrefix("CADefaultDeviceAggregate")
            else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    static func device(uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.uid == uid }
    }

    static func name(of id: AudioDeviceID) -> String? {
        string(kAudioObjectPropertyName, of: id)
    }

    /// Calls `handler` whenever the device list or the default input changes.
    /// Keep the returned token alive for as long as notifications are wanted.
    static func observeChanges(_ handler: @escaping @Sendable () -> Void) -> ChangeToken {
        ChangeToken(handler: handler)
    }

    final class ChangeToken: @unchecked Sendable {
        private let selectors: [AudioObjectPropertySelector] = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
        private let block: AudioObjectPropertyListenerBlock
        private let queue = DispatchQueue(label: "com.zoezyla.voice.devices")

        fileprivate init(handler: @escaping @Sendable () -> Void) {
            block = { _, _ in handler() }
            for selector in selectors {
                var addr = AudioDevices.address(selector)
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            }
        }

        deinit {
            for selector in selectors {
                var addr = AudioDevices.address(selector)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
            }
        }
    }
}

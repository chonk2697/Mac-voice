import AVFoundation
import CoreAudio
import Foundation

/// A microphone as the picker shows it. `uid` is AVCaptureDevice's uniqueID,
/// which on macOS is the Core Audio device UID.
nonisolated struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// Microphone enumeration plus Core Audio change notifications.
nonisolated enum AudioDevices {
    /// Every attached microphone, as AVCaptureDevice lists them.
    static func inputDevices() -> [AudioInputDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                         mediaType: .audio, position: .unspecified)
        return discovery.devices.map { AudioInputDevice(uid: $0.uniqueID, name: $0.localizedName) }
    }

    /// Name of the system default input, if any.
    static func defaultInputName() -> String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
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

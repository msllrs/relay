import CoreAudio
import Foundation

/// Observes CoreAudio hardware changes: input device hotplug and
/// default-input-device switches. Callbacks fire on the main actor.
@MainActor
final class AudioDeviceMonitor {
    var onDevicesChanged: (() -> Void)?
    var onDefaultInputDeviceChanged: (() -> Void)?

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?

    func start() {
        guard devicesListener == nil, defaultInputListener == nil else { return }

        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.onDevicesChanged?()
            }
        }
        if AudioObjectAddPropertyListenerBlock(
            Self.systemObject, &devicesAddress, .main, devicesBlock
        ) == noErr {
            devicesListener = devicesBlock
        }

        let defaultInputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.onDefaultInputDeviceChanged?()
            }
        }
        if AudioObjectAddPropertyListenerBlock(
            Self.systemObject, &defaultInputAddress, .main, defaultInputBlock
        ) == noErr {
            defaultInputListener = defaultInputBlock
        }
    }

    func stop() {
        if let listener = devicesListener {
            AudioObjectRemovePropertyListenerBlock(Self.systemObject, &devicesAddress, .main, listener)
            devicesListener = nil
        }
        if let listener = defaultInputListener {
            AudioObjectRemovePropertyListenerBlock(Self.systemObject, &defaultInputAddress, .main, listener)
            defaultInputListener = nil
        }
    }
}

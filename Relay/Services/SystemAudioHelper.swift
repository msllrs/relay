import AVFoundation
import CoreAudio

/// Helpers for system audio input device volume control and safe format retrieval.
enum SystemAudioHelper {
    /// Returns the default input device's AudioObjectID, or `nil` if unavailable.
    static func defaultInputDevice() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Gets the current input volume (0.0–1.0). Uses the specified device, or system default if `nil`.
    static func getInputVolume(deviceID: AudioDeviceID? = nil) -> Float? {
        guard let deviceID = deviceID ?? defaultInputDevice() else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Check if the property is settable on element 0, otherwise try element 1
        var element: UInt32 = 0
        var settable: DarwinBoolean = false
        var status = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        if status != noErr || !settable.boolValue {
            element = 1
            address.mElement = element
        }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return volume
    }

    /// Sets the input volume (0.0–1.0). Uses the specified device, or system default if `nil`.
    @discardableResult
    static func setInputVolume(_ volume: Float, deviceID: AudioDeviceID? = nil) -> Bool {
        guard let deviceID = deviceID ?? defaultInputDevice() else { return false }
        var vol = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var settable: DarwinBoolean = false
        var status = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        if status != noErr || !settable.boolValue {
            address.mElement = 1
        }

        status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
        return status == noErr
    }

    /// A device muted at the CoreAudio level records pure silence with no
    /// error anywhere. Check and auto-unmute before capturing (some apps and
    /// utilities leave the input muted behind the user's back).
    static func ensureInputUnmuted(deviceID: AudioDeviceID? = nil) {
        guard let deviceID = deviceID ?? defaultInputDevice() else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr,
              muted == 1 else { return }

        var unmuted: UInt32 = 0
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &unmuted)
        if status == noErr {
            NSLog("SystemAudioHelper: input device %d was muted at device level - auto-unmuted", deviceID)
        } else {
            NSLog("SystemAudioHelper: failed to unmute input device %d (%d)", deviceID, status)
        }
    }

    // MARK: - Output volume (for ducking during recording)

    /// Returns the default output device's AudioObjectID, or `nil` if unavailable.
    static func defaultOutputDevice() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Gets the current output volume (0.0–1.0), or `nil` when the device has
    /// no software volume control.
    static func getOutputVolume() -> Float? {
        guard let deviceID = defaultOutputDevice() else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var settable: DarwinBoolean = false
        var status = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        if status != noErr || !settable.boolValue {
            address.mElement = 1
        }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return volume
    }

    /// Sets the output volume (0.0–1.0) on the default output device.
    @discardableResult
    static func setOutputVolume(_ volume: Float) -> Bool {
        guard let deviceID = defaultOutputDevice() else { return false }
        var vol = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var settable: DarwinBoolean = false
        var status = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        if status != noErr || !settable.boolValue {
            address.mElement = 1
        }

        status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
        return status == noErr
    }
}

// MARK: - AVAudioEngine safe input format

extension AVAudioEngine {
    /// Returns a valid recording format, working around AirPods and other devices
    /// that may report 0 channels via `outputFormat(forBus:)`.
    func validInputFormat() -> AVAudioFormat {
        let outputFmt = inputNode.outputFormat(forBus: 0)
        if outputFmt.channelCount > 0 && outputFmt.sampleRate > 0 {
            return outputFmt
        }

        // Some devices (e.g. AirPods) report 0 channels on outputFormat;
        // try inputFormat instead.
        let inputFmt = inputNode.inputFormat(forBus: 0)
        if inputFmt.channelCount > 0 && inputFmt.sampleRate > 0 {
            return inputFmt
        }

        // Last resort: 44100 Hz mono PCM
        return AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    }
}

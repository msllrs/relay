import AVFoundation
import CoreAudio

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

enum AudioDeviceManager {
    /// Returns all available audio input devices.
    static func inputDevices() -> [AudioDevice] {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return [] }

        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceIDs
        )
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            // Check if device has input channels
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { return nil }

            let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPtr.deallocate() }

            guard AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &streamSize, bufferListPtr) == noErr else {
                return nil
            }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { return nil }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef) == noErr,
                  let name = nameRef?.takeRetainedValue() as String? else {
                return nil
            }

            // Filter out virtual aggregate devices created by macOS
            if name.hasPrefix("CADefaultDeviceAggregate") { return nil }

            return AudioDevice(id: deviceID, name: name)
        }
    }

    /// Sets the input device on an AVAudioEngine's underlying audio unit.
    @discardableResult
    static func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) -> Bool {
        var devID = deviceID
        let status = AudioUnitSetProperty(
            engine.inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }
}

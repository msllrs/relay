import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// Microphone capture built directly on the HAL output unit (AUHAL) instead of
/// AVAudioEngine. This sidesteps the stale-audio-graph class of bugs entirely:
/// the unit records from an explicit device without touching the system
/// default, survives device switches mid-recording via stop → reconfigure →
/// restart, and folds multichannel inputs down with a channel map.
final class AUHALCaptureSource: AudioCaptureSource, @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case componentNotFound
        case osStatus(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .componentNotFound: "Audio input component unavailable."
            case .osStatus(let stage, let status): "Audio capture failed at \(stage) (\(status))."
            }
        }
    }

    /// Serializes start/stop/switchDevice. Never used from the render thread.
    private let controlQueue = DispatchQueue(label: "com.msllrs.relay.auhal-control")
    /// Conversion + delivery, off the realtime thread.
    private let processingQueue = DispatchQueue(label: "com.msllrs.relay.auhal-processing")

    // Control-queue-guarded state.
    private var audioUnit: AudioUnit?
    private var isInitialized = false
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var onLevel: (@Sendable (Float) -> Void)?
    private var currentDeviceID: AudioDeviceID = 0
    /// True when the caller asked for the system default rather than an explicit device.
    private var followsDefault = false

    // Read from the render thread while capture is active; only mutated while
    // the unit is stopped.
    private var monoInputFormat: AVAudioFormat?
    private var renderBuffer: UnsafeMutablePointer<Float32>?
    private var renderBufferCapacity: UInt32 = 0

    // Realtime-safe flags.
    private let captureActive = Atomic<Bool>(false)
    private let callbacksInFlight = Atomic<Int>(0)
    private let droppedBuffers = Atomic<Int>(0)

    /// Confined to processingQueue.
    private let monoConverter = PCM16kMonoConverter()

    deinit {
        stop()
        renderBuffer?.deallocate()
    }

    // MARK: - AudioCaptureSource

    func start(
        deviceID: AudioDeviceID?,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        try controlQueue.sync {
            teardownLocked()
            self.onBuffer = onBuffer
            self.onLevel = onLevel
            self.followsDefault = (deviceID == nil)
            let resolved = deviceID ?? Self.systemDefaultInputDevice()
            guard let resolved, resolved != kAudioObjectUnknown else {
                throw CaptureError.osStatus("resolving input device", kAudioHardwareBadDeviceError)
            }
            try buildAndStartLocked(deviceID: resolved)
        }
    }

    func switchDevice(to deviceID: AudioDeviceID?) {
        controlQueue.sync {
            guard let unit = audioUnit, captureActive.load(ordering: .acquiring) else { return }
            followsDefault = (deviceID == nil)
            guard let newDevice = deviceID ?? Self.systemDefaultInputDevice(),
                  newDevice != kAudioObjectUnknown,
                  newDevice != currentDeviceID else { return }

            let oldDevice = currentDeviceID
            stopUnitLocked(unit)
            AudioUnitUninitialize(unit)
            isInitialized = false

            do {
                try configureAndStartLocked(unit: unit, deviceID: newDevice)
                NSLog("AUHALCaptureSource: switched capture %d -> %d", oldDevice, newDevice)
            } catch {
                // Roll back to the previous device so the recording keeps audio.
                NSLog("AUHALCaptureSource: switch to %d failed (%@); rolling back", newDevice, error.localizedDescription)
                try? configureAndStartLocked(unit: unit, deviceID: oldDevice)
            }
        }
    }

    func stop() {
        controlQueue.sync {
            teardownLocked()
        }
    }

    // MARK: - Unit lifecycle (control queue)

    private func buildAndStartLocked(deviceID: AudioDeviceID) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw CaptureError.componentNotFound
        }

        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "creating unit")
        guard let unit else { throw CaptureError.componentNotFound }
        audioUnit = unit

        var enableInput: UInt32 = 1
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enableInput, UInt32(MemoryLayout<UInt32>.size)
        ), "enabling input")

        var disableOutput: UInt32 = 0
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &disableOutput, UInt32(MemoryLayout<UInt32>.size)
        ), "disabling output")

        var callback = AURenderCallbackStruct(
            inputProc: AUHALCaptureSource.renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ), "setting input callback")

        try configureAndStartLocked(unit: unit, deviceID: deviceID)
    }

    /// Points the (stopped, uninitialized) unit at a device, negotiates a mono
    /// Float32 client format at the device rate, then initializes and starts.
    private func configureAndStartLocked(unit: AudioUnit, deviceID: AudioDeviceID) throws {
        SystemAudioHelper.ensureInputUnmuted(deviceID: deviceID)

        var device = deviceID
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
        ), "setting device")

        var deviceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
            &deviceFormat, &formatSize
        ), "reading device format")

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try check(AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ), "setting client format")

        // Fold the device down to its preferred input channel; multichannel
        // interfaces otherwise deliver the wrong channel or silence.
        if deviceFormat.mChannelsPerFrame > 1 {
            var channelMap: [Int32] = [Int32(Self.preferredInputChannel(deviceID: deviceID, channelCount: deviceFormat.mChannelsPerFrame))]
            _ = channelMap.withUnsafeMutableBytes { bytes in
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
                    bytes.baseAddress, UInt32(bytes.count)
                )
            }
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: deviceFormat.mSampleRate, channels: 1) else {
            throw CaptureError.osStatus("building mono format", kAudio_ParamError)
        }
        monoInputFormat = format
        ensureRenderBufferLocked(frames: 8192)

        try check(AudioUnitInitialize(unit), "initializing unit")
        isInitialized = true

        captureActive.store(true, ordering: .releasing)
        do {
            try check(AudioOutputUnitStart(unit), "starting unit")
        } catch {
            captureActive.store(false, ordering: .releasing)
            throw error
        }
        currentDeviceID = deviceID
    }

    private func stopUnitLocked(_ unit: AudioUnit) {
        captureActive.store(false, ordering: .releasing)
        AudioOutputUnitStop(unit)
        // Bounded wait for in-flight render callbacks so reconfiguration never
        // races the realtime thread.
        var attempts = 0
        while callbacksInFlight.load(ordering: .acquiring) > 0, attempts < 100 {
            usleep(500)
            attempts += 1
        }
    }

    private func teardownLocked() {
        if let unit = audioUnit {
            stopUnitLocked(unit)
            if isInitialized {
                AudioUnitUninitialize(unit)
            }
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
        isInitialized = false
        currentDeviceID = 0
        processingQueue.sync {} // drain pending deliveries before dropping callbacks
        onBuffer = nil
        onLevel = nil
        let dropped = droppedBuffers.exchange(0, ordering: .relaxed)
        if dropped > 0 {
            NSLog("AUHALCaptureSource: dropped %d oversized buffers", dropped)
        }
    }

    private func ensureRenderBufferLocked(frames: UInt32) {
        guard frames > renderBufferCapacity else { return }
        renderBuffer?.deallocate()
        renderBuffer = UnsafeMutablePointer<Float32>.allocate(capacity: Int(frames))
        renderBufferCapacity = frames
    }

    private func check(_ status: OSStatus, _ stage: String) throws {
        guard status == noErr else { throw CaptureError.osStatus(stage, status) }
    }

    // MARK: - Render path (realtime thread)

    private static let renderCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
        let source = Unmanaged<AUHALCaptureSource>.fromOpaque(inRefCon).takeUnretainedValue()
        return source.handleInput(
            ioActionFlags: ioActionFlags,
            inTimeStamp: inTimeStamp,
            inBusNumber: inBusNumber,
            inNumberFrames: inNumberFrames
        )
    }

    private func handleInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        callbacksInFlight.wrappingAdd(1, ordering: .acquiringAndReleasing)
        defer { callbacksInFlight.wrappingSubtract(1, ordering: .acquiringAndReleasing) }

        guard captureActive.load(ordering: .acquiring),
              let unit = audioUnit,
              let renderBuffer,
              inNumberFrames <= renderBufferCapacity,
              let format = monoInputFormat
        else {
            if inNumberFrames > renderBufferCapacity {
                droppedBuffers.wrappingAdd(1, ordering: .relaxed)
            }
            return noErr
        }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: inNumberFrames * UInt32(MemoryLayout<Float32>.size),
                mData: renderBuffer
            )
        )

        let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList)
        guard status == noErr else { return status }

        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: inNumberFrames),
              let dst = copy.floatChannelData?[0]
        else { return noErr }
        copy.frameLength = inNumberFrames
        dst.update(from: renderBuffer, count: Int(inNumberFrames))

        let wrapped = UncheckedSendableBuffer(buffer: copy)
        processingQueue.async { [weak self] in
            self?.deliver(wrapped.buffer)
        }
        return noErr
    }

    /// Runs on processingQueue.
    private func deliver(_ buffer: AVAudioPCMBuffer) {
        guard captureActive.load(ordering: .acquiring) else { return }
        guard let converted = monoConverter.convert(buffer) else { return }
        onLevel?(PCM16kMonoConverter.rms(of: converted))
        onBuffer?(converted)
    }

    // MARK: - Device helpers

    private static func systemDefaultInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// 0-based index of the channel to capture: the device's preferred stereo
    /// left channel when available, else channel 0.
    private static func preferredInputChannel(deviceID: AudioDeviceID, channelCount: UInt32) -> UInt32 {
        var channels = [UInt32](repeating: 0, count: 2)
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &channels)
        // Preferred channels are 1-based.
        guard status == noErr, channels[0] >= 1, channels[0] <= channelCount else { return 0 }
        return channels[0] - 1
    }
}

/// Shuttles a freshly-created AVAudioPCMBuffer across a queue hop. The buffer
/// must not be touched from the sending context after wrapping.
struct UncheckedSendableBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

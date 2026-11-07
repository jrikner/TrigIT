import AVFoundation
import CoreAudio
import Foundation
import TrigITProtocols

/// An audio device with at least one input channel.
struct AudioInputDevice: Hashable, Identifiable {
    let id: AudioDeviceID
    /// Stable across reboots and reconnections; this is what a Set should remember.
    let uid: String
    let name: String
    let channelCount: Int
}

/// Lists audio input devices through Core Audio and reports when the list changes.
final class AudioDeviceList {
    /// Called on the main queue when devices are added or removed.
    var onChange: (() -> Void)?
    private var listener: AudioObjectPropertyListenerBlock?

    init() {
        var address = Self.address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            listener = block
        }
    }

    deinit {
        guard let listener else { return }
        var address = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    func inputDevices() -> [AudioInputDevice] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let channels = Self.inputChannelCount(id)
            guard channels > 0 else { return nil }
            return AudioInputDevice(
                id: id,
                uid: Self.string(id, kAudioDevicePropertyDeviceUID) ?? "device-\(id)",
                name: Self.string(id, kAudioObjectPropertyName) ?? "Audio device \(id)",
                channelCount: channels
            )
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Reads LTC from one channel of an audio input device and decodes it.
final class LTCAudioInput {
    enum StartError: LocalizedError {
        case microphoneAccessDenied
        case noAudioUnit
        case cannotSelectDevice(OSStatus)
        case channelOutOfRange(Int, available: Int)

        var errorDescription: String? {
            switch self {
            case .microphoneAccessDenied:
                return "audio input access is denied; allow it in System Settings → Privacy & Security → Microphone"
            case .noAudioUnit: return "the audio input could not be opened"
            case .cannotSelectDevice(let status): return "the audio device could not be selected (error \(status))"
            case .channelOutOfRange(let channel, let available):
                return "channel \(channel + 1) does not exist; the device has \(available)"
            }
        }
    }

    /// Called on the main queue for each decoded frame, with the monotonic
    /// time (seconds, same clock as `ProcessInfo.systemUptime`) at which the
    /// frame started.
    var onFrame: ((LTCFrame, Double) -> Void)?
    /// The input's peak level (0...1), about ten times a second.
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?

    /// Starts reading `channel` (0-based) of `device`. Replaces any running input.
    func start(device: AudioDeviceID, channel: Int, completion: @escaping (Error?) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard granted else { return completion(StartError.microphoneAccessDenied) }
                do {
                    try self.startEngine(device: device, channel: channel)
                    completion(nil)
                } catch {
                    completion(error)
                }
            }
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func startEngine(device: AudioDeviceID, channel: Int) throws {
        stop()
        // A fresh engine for every start: switching devices on a used engine is unreliable.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw StartError.noAudioUnit }
        var deviceID = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw StartError.cannotSelectDevice(status) }

        let format = input.inputFormat(forBus: 0)
        guard channel < Int(format.channelCount) else {
            throw StartError.channelOutOfRange(channel, available: Int(format.channelCount))
        }
        let sampleRate = format.sampleRate

        // The decoder and its sample counter live on the audio thread only.
        var decoder = LTCDecoder(sampleRate: sampleRate)
        var samplesFed = 0
        var peak: Float = 0
        var buffersSinceLevel = 0
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, time in
            guard let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let bufferStart = samplesFed
            samplesFed += count
            let bufferTime = time.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: time.hostTime)
                : ProcessInfo.processInfo.systemUptime - Double(count) / sampleRate
            let samples = Array(UnsafeBufferPointer(start: channels[channel], count: count))
            peak = max(peak, samples.reduce(0) { max($0, abs($1)) })
            buffersSinceLevel += 1
            if buffersSinceLevel >= 8 {
                let level = min(peak, 1)
                peak = 0
                buffersSinceLevel = 0
                DispatchQueue.main.async { self?.onLevel?(level) }
            }
            let frames = decoder.decode(samples)
            guard !frames.isEmpty else { return }
            let stamped = frames.map { ($0, bufferTime + Double($0.startSample - bufferStart) / sampleRate) }
            DispatchQueue.main.async {
                for (frame, time) in stamped { self?.onFrame?(frame, time) }
            }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }
}

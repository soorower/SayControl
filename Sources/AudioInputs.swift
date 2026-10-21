// The microphones this Mac can hear through, straight from CoreAudio: the
// built-in one, a headset, a USB mic, an iPhone over Continuity. Dictation
// records from the Mac's default input, so "use this one" makes it the
// default, which is also what every other app then hears through.
import CoreAudio
import Foundation

struct AudioInput: Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    /// An iPhone's microphone over Continuity, by cable or over the air.
    /// macOS lets the phone's mic sleep the moment nothing is listening, so
    /// every take from it waits ~3–4 s in engine.start() while the phone
    /// wakes (measured by cable, even 5 s after the last take).
    var isContinuity = false
}

enum AudioInputs {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let s = value else { return nil }
        return s as String
    }

    /// Every device with at least one input stream, in CoreAudio's order.
    static func all() -> [AudioInput] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  isUsable(id), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioInput(id: id, name: name, uid: string(id, kAudioDevicePropertyDeviceUID) ?? name,
                              isContinuity: isContinuity(id))
        }
    }

    private static func uint32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// Only a microphone that can be picked right now; virtual and
    /// aggregate devices are other apps' plumbing, not microphones.
    private static func isUsable(_ id: AudioDeviceID) -> Bool {
        if uint32(id, kAudioDevicePropertyDeviceIsAlive) == 0 { return false }
        switch uint32(id, kAudioDevicePropertyTransportType) {
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return false
        default:
            return true
        }
    }

    private static func isContinuity(_ id: AudioDeviceID) -> Bool {
        switch uint32(id, kAudioDevicePropertyTransportType) {
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            return true
        default:
            return false
        }
    }

    static var defaultID: AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    static var `default`: AudioInput? {
        guard let id = defaultID else { return nil }
        return all().first { $0.id == id }
    }

    @discardableResult
    static func makeDefault(_ input: AudioInput) -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = input.id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        return status == noErr
    }
}

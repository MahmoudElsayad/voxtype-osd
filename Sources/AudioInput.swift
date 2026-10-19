import Foundation
import CoreAudio

struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let name: String
}

struct AudioInputSnapshot: Equatable {
    let devices: [AudioInputDevice]
    let defaultID: AudioDeviceID
}

enum RecordingInput: Equatable {
    case systemDefault
    case configured(String)
    case unavailable

    static func parse(_ output: String) -> RecordingInput {
        var inAudio = false
        for line in output.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inAudio = line == "[audio]"; continue }
            if inAudio, line.hasPrefix("device = ") {
                let value = String(line.dropFirst("device = ".count))
                if value == "\"default\"" { return .systemDefault }
                guard value.hasPrefix("\""), value.hasSuffix("\"") else { return .unavailable }
                let name = (try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? String(value.dropFirst().dropLast())
                return .configured(name)
            }
        }
        return .unavailable
    }
}

/// Reads the macOS input directly. No separate microphone preference can drift from it.
final class AudioInputController {
    private let read: () throws -> AudioInputSnapshot
    private let setDefault: (AudioDeviceID) throws -> Void
    private let isRecording: () -> Bool
    private let recordingDeviceName: () -> String?
    private(set) var snapshot = AudioInputSnapshot(devices: [], defaultID: kAudioObjectUnknown)
    private(set) var recordingInput: RecordingInput = .unavailable
    private var readError: String?
    private var selectionError: String?
    var error: String? { selectionError ?? readError }
    var onChange: (() -> Void)?
    var recording: Bool { isRecording() }
    var canSelect: Bool { recordingInput == .systemDefault && !recording && readError == nil && !snapshot.devices.isEmpty }
    var title: String {
        if recording { return recordingDeviceName() ?? "Recording device unavailable" }
        if case .configured(let name) = recordingInput { return name }
        if readError != nil { return "Microphone unavailable" }
        return snapshot.devices.first { $0.id == snapshot.defaultID }?.name ?? "No input available"
    }
    var caption: String {
        if let error { return error }
        switch recordingInput {
        case .unavailable: return "Cannot read Voxtype input. Reopen Settings to retry."
        case .configured: return "Voxtype uses a fixed device in its configuration."
        case .systemDefault:
            if recording { return "Recording now. Stop to change the macOS input." }
            return "Uses macOS input for the next recording. Changes affect other apps too."
        }
    }

    init(read: @escaping () throws -> AudioInputSnapshot = MacAudioInput.snapshot,
         setDefault: @escaping (AudioDeviceID) throws -> Void = MacAudioInput.select,
         recordingDeviceName: @escaping () -> String? = AudioInputController.activeRecordingDevice,
         isRecording: @escaping () -> Bool = {
             (try? String(contentsOfFile: "/tmp/voxtype/state", encoding: .utf8))?
                 .trimmingCharacters(in: .whitespacesAndNewlines) == "recording"
         }) {
        self.read = read
        self.setDefault = setDefault
        self.isRecording = isRecording
        self.recordingDeviceName = recordingDeviceName
    }

    func setRecordingInput(_ input: RecordingInput) {
        recordingInput = input
        onChange?()
    }

    func refresh() {
        do { snapshot = try read(); readError = nil }
        catch { self.readError = "Cannot read macOS microphones. Retrying." }
        onChange?()
    }

    func select(_ id: AudioDeviceID) {
        guard canSelect, snapshot.devices.contains(where: { $0.id == id }) else { return }
        do {
            try setDefault(id)
            snapshot = try read()
            guard snapshot.defaultID == id else { throw AudioInputError.operationFailed }
            selectionError = nil
        } catch {
            selectionError = "Cannot change microphone. Try again or use macOS Sound."
            if let current = try? read() { snapshot = current }
        }
        onChange?()
    }

    /// The CLI reports the resolved device, including defaults and the platform config path.
    func loadRecordingInput() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let executable = ["/opt/homebrew/bin/voxtype", "/usr/local/bin/voxtype"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            let data = executable.flatMap { BoundedCommand.run($0, arguments: ["config"], timeout: 3) }
            let input = data.map { RecordingInput.parse(String(decoding: $0, as: UTF8.self)) } ?? .unavailable
            let resolved = input
            DispatchQueue.main.async { self?.setRecordingInput(resolved) }
        }
    }

    static func activeRecordingDevice() -> String? {
        let path = NSHomeDirectory() + "/Library/Logs/voxtype/stdout.log"
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        guard let length = try? file.seekToEnd() else { return nil }
        try? file.seek(toOffset: length > 32768 ? length - 32768 : 0)
        guard let data = try? file.readToEnd() else { return nil }
        return recordingDevice(in: String(decoding: data, as: UTF8.self))
    }

    static func recordingDevice(in log: String) -> String? {
        let clean = log.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        // Only accept a device from the latest recording, never a stale prior stream.
        guard let start = clean.range(of: "Recording started", options: .backwards) else { return nil }
        let latest = clean[start.lowerBound...]
        guard !latest.contains("Recording stopped"),
              let marker = latest.range(of: "Using audio device: ") else { return nil }
        return latest[marker.upperBound...].split(separator: "\n").first.map(String.init)
    }

}

enum AudioInputError: Error { case operationFailed }

enum MacAudioInput {
    static func snapshot() throws -> AudioInputSnapshot {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { throw AudioInputError.operationFailed }
        guard size > 0 else { return AudioInputSnapshot(devices: [], defaultID: kAudioObjectUnknown) }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { throw AudioInputError.operationFailed }
        let devices = ids.compactMap { id -> AudioInputDevice? in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                     mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { storage.deallocate() }
            guard AudioObjectGetPropertyData(id, &streams, 0, nil, &bytes, storage) == noErr else { return nil }
            let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            guard buffers.contains(where: { $0.mNumberChannels > 0 }) else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr else { return nil }
            guard let name else { return nil }
            return AudioInputDevice(id: id, name: name.takeRetainedValue() as String)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        address.mSelector = kAudioHardwarePropertyDefaultInputDevice
        var current = AudioDeviceID(kAudioObjectUnknown)
        size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &current) == noErr else { throw AudioInputError.operationFailed }
        return AudioInputSnapshot(devices: devices, defaultID: current)
    }

    static func select(_ id: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var device = id
        guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         UInt32(MemoryLayout<AudioDeviceID>.size), &device) == noErr else { throw AudioInputError.operationFailed }
    }
}

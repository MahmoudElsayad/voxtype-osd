import Foundation
import CoreAudio
import os

struct MediaSnapshot: Decodable {
    let playing: Bool
    let processIdentifier: Int
    let bundleIdentifier: String
    let contentItemIdentifier: String?
    let uniqueIdentifier: String?
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?

    func isSameSession(as other: MediaSnapshot) -> Bool {
        guard processIdentifier == other.processIdentifier,
              bundleIdentifier == other.bundleIdentifier else { return false }
        // Browser Now Playing identifiers can change when the same video pauses.
        if let title, !title.isEmpty, let otherTitle = other.title, !otherTitle.isEmpty {
            return title == otherTitle && artist == other.artist && album == other.album && duration == other.duration
        }
        if let contentItemIdentifier, !contentItemIdentifier.isEmpty {
            return contentItemIdentifier == other.contentItemIdentifier
        }
        if let uniqueIdentifier, !uniqueIdentifier.isEmpty {
            return uniqueIdentifier == other.uniqueIdentifier
        }
        guard let title, !title.isEmpty else { return false }
        return other.contentItemIdentifier == nil && other.uniqueIdentifier == nil &&
            title == other.title && artist == other.artist && album == other.album && duration == other.duration
    }
}

enum MediaControl {
    static let path: String? = {
        let directories = ["/opt/homebrew/bin", "/usr/local/bin"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return directories.map { $0 + "/media-control" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func snapshot() -> MediaSnapshot? {
        guard let path,
              let data = BoundedCommand.run(path, arguments: ["get", "--no-artwork"], timeout: 3)
        else { return nil }
        return try? JSONDecoder().decode(MediaSnapshot.self, from: data)
    }

    static func send(_ command: String) -> Bool {
        guard let path else { return false }
        return BoundedCommand.run(path, arguments: [command], timeout: 3) != nil
    }
}

enum PlaybackReadiness {
    static func isReady() -> Bool {
        var output = AudioDeviceID(0)
        guard read(kAudioHardwarePropertyDefaultOutputDevice, object: AudioObjectID(kAudioObjectSystemObject), into: &output) else { return true }
        var transport = UInt32(0)
        guard read(kAudioDevicePropertyTransportType, object: output, into: &transport),
              transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else { return true }
        var rate = Float64(0)
        guard read(kAudioDevicePropertyNominalSampleRate, object: output, into: &rate) else { return true }
        return rate >= 44_100
    }

    private static func read<T>(_ selector: AudioObjectPropertySelector, object: AudioObjectID, into value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr
        }
    }
}

/// Only a matching player and item that this app paused can resume.
final class RecordingMedia {
    private let queue: DispatchQueue
    private let snapshot: () -> MediaSnapshot?
    private let send: (String) -> Bool
    private let playbackReady: () -> Bool
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var recording = false
    private var generation = 0
    private var pausedSession: MediaSnapshot?
    private let logger = Logger(subsystem: "io.github.mahmoudelsayad.voxtype-osd", category: "media")

    init(queue: DispatchQueue = DispatchQueue(label: "io.github.mahmoudelsayad.voxtype-osd.media"),
         snapshot: @escaping () -> MediaSnapshot? = MediaControl.snapshot,
         send: @escaping (String) -> Bool = MediaControl.send,
         playbackReady: @escaping () -> Bool = PlaybackReadiness.isReady,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
             DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: action)
         }) {
        self.queue = queue
        self.snapshot = snapshot
        self.send = send
        self.playbackReady = playbackReady
        self.schedule = schedule
    }

    func setRecording(_ active: Bool) {
        queue.async { [self] in
            guard active != recording else { return }
            recording = active
            generation += 1
            if active {
                pause()
            } else {
                // The microphone closes asynchronously when the daemon leaves recording.
                scheduleResume(generation: generation, retries: 25, delay: 0.6)
            }
        }
    }

    func restoreOnQuit() {
        queue.sync {
            generation += 1
            resume()
        }
    }

    private func pause() {
        guard let current = snapshot() else { return }
        if let pausedSession, !current.playing, pausedSession.isSameSession(as: current) { return }
        pausedSession = nil
        guard current.playing else { return }
        guard send("pause") else {
            logger.notice("Media pause failed")
            return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        for attempt in 0..<7 {
            if attempt > 0 {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard let paused = snapshot() else { continue }
            guard current.isSameSession(as: paused) else { break }
            if !paused.playing {
                pausedSession = paused
                return
            }
        }
        logger.notice("Media pause was not confirmed")
    }

    private func scheduleResume(generation expected: Int, retries: Int, delay: TimeInterval) {
        guard pausedSession != nil else { return }
        schedule(delay) { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard !self.recording, self.generation == expected else { return }
                if retries > 0, !self.playbackReady() {
                    self.scheduleResume(generation: expected, retries: retries - 1, delay: 0.2)
                } else {
                    self.resume()
                }
            }
        }
    }

    private func resume() {
        guard let pausedSession else { return }
        self.pausedSession = nil
        guard let current = snapshot(), !current.playing,
              pausedSession.isSameSession(as: current) else { return }
        if !send("play") { logger.notice("Media resume failed") }
    }
}

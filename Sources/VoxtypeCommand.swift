import Foundation
import os

/// Runs `voxtype record <command>` in order, off the main thread.
///
/// `voxtype record` finds the daemon through the PID in `/tmp/voxtype/voxtype.lock`. macOS
/// deletes old files from `/tmp`, so a daemon that runs for days loses this file, and every
/// command then fails with "daemon is not running" while the daemon still runs. When that
/// happens and exactly one daemon process is alive, its PID is written back and the command
/// runs again.
final class VoxtypeCommand {
    struct Outcome: Equatable {
        var status: Int32
        var stderr: String
    }

    static let lockFile = "/tmp/voxtype/voxtype.lock"

    /// Homebrew installs to /opt/homebrew on Apple silicon and /usr/local on Intel Macs.
    private static let executable = ["/opt/homebrew/bin/voxtype", "/usr/local/bin/voxtype"]
        .map(URL.init(fileURLWithPath:))
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        ?? URL(fileURLWithPath: "/opt/homebrew/bin/voxtype")
    private static let log = Logger(subsystem: "io.github.mahmoudelsayad.voxtype-osd", category: "voxtype")

    private let queue = DispatchQueue(label: "voxtype-osd.record")
    private let execute: ([String]) -> Outcome
    private let daemonPIDs: () -> [Int32]
    private let lockFile: String

    init(execute: @escaping ([String]) -> Outcome = VoxtypeCommand.launch,
         daemonPIDs: @escaping () -> [Int32] = VoxtypeCommand.runningDaemons,
         lockFile: String = VoxtypeCommand.lockFile) {
        self.execute = execute
        self.daemonPIDs = daemonPIDs
        self.lockFile = lockFile
    }

    func run(_ command: String) {
        queue.async { self.runNow(command) }
    }

    /// Runs the command on the calling thread and returns whether it succeeded.
    @discardableResult
    func runNow(_ command: String) -> Bool {
        let arguments = ["record", command]
        var outcome = execute(arguments)
        if outcome.status != 0, outcome.stderr.contains("daemon is not running"), restoreLockFile() {
            outcome = execute(arguments)
        }
        guard outcome.status != 0 else { return true }
        let message = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.log.error("voxtype record \(command, privacy: .public) failed (\(outcome.status)): \(message, privacy: .public)")
        return false
    }

    /// Writes the PID of the one running daemon to the lock file. Returns false when no daemon
    /// runs or several do, because then there is no PID that is safe to write.
    private func restoreLockFile() -> Bool {
        let pids = daemonPIDs()
        guard pids.count == 1, let pid = pids.first else {
            Self.log.error("voxtype lock file missing; found \(pids.count) daemon processes, so it is not restored")
            return false
        }
        do {
            try FileManager.default.createDirectory(
                atPath: (lockFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try String(pid).write(toFile: lockFile, atomically: true, encoding: .utf8)
        } catch {
            Self.log.error("could not restore \(self.lockFile, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        Self.log.notice("restored \(self.lockFile, privacy: .public) with daemon PID \(pid)")
        return true
    }

    static func launch(_ arguments: [String]) -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return Outcome(status: -1, stderr: "could not launch \(executable.path): \(error.localizedDescription)")
        }
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Outcome(status: process.terminationStatus, stderr: String(decoding: data, as: UTF8.self))
    }

    /// PIDs of `voxtype daemon` processes, from the Voxtype app or from Homebrew.
    static func runningDaemons() -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-u", String(getuid()), "-f", "^/.*/voxtype(-bin)? daemon$"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
    }
}

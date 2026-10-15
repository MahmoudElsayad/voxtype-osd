import AppKit

/// The dictation keys, chosen in Settings. Voxtype's own listener is off
/// (`[hotkey] enabled = false`) because it knows one key and one mode; this drives the daemon
/// through `voxtype record` instead.
///
/// The rules protect a long recording: only a deliberate action can stop or discard it.
/// - Hold the push-to-talk key: releasing it stops and transcribes.
/// - The hands-free key with the push-to-talk key, in either order: recording continues after
///   the keys are released. A clean tap of the push-to-talk key stops and transcribes; a tap
///   that includes another key was a shortcut, and recording continues.
/// - Cancel: the cancel key during recording or while Voxtype transcribes.
/// - Another key within the first second of holding push-to-talk was a shortcut such as
///   Command-C, so the short recording it started is discarded. Later keys are ignored.
/// - A recording this app did not start, for example one running when the app relaunched,
///   is adopted as hands-free.
final class Hotkeys {
    enum Mode: Equatable {
        case idle
        /// Push-to-talk is held. `since` tells a shortcut from a stray key during dictation.
        case holding(since: Date)
        case handsFree
        /// Push-to-talk went down during hands-free. Its release stops, unless another key
        /// made it a shortcut.
        case stopArmed
    }

    static let shortcutWindow: TimeInterval = 1

    /// Called on the main thread when the mode changes.
    var onModeChange: (Mode) -> Void = { _ in }
    /// Called when a recording is discarded because the keys were a shortcut, not dictation.
    var onShortcutAbort: () -> Void = {}
    /// Called once the app has Accessibility permission and the key monitors are live.
    var onListening: () -> Void = {}
    /// Voxtype's state file: "idle", "recording" or "transcribing".
    var daemonState: () -> String = {
        ((try? String(contentsOfFile: "/tmp/voxtype/state", encoding: .utf8)) ?? "idle")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var now: () -> Date = Date.init

    var settings = Settings() {
        didSet {
            pushToTalkDown = false
            handsFreeDown = false
        }
    }

    private(set) var mode: Mode = .idle {
        didSet { if mode != oldValue { onModeChange(mode) } }
    }
    private var pushToTalkDown = false
    private var handsFreeDown = false
    private var monitors: [Any] = []
    private let run: (String) -> Void

    /// `run` receives `start`, `stop` or `cancel`; it defaults to `voxtype record <command>`.
    init(run: @escaping (String) -> Void = VoxtypeCommand().run) {
        self.run = run
    }

    /// Global key monitors receive nothing without Accessibility permission, so this waits for
    /// the permission and installs them as soon as it is granted.
    func start() {
        adoptRunningRecording()
        guard AXIsProcessTrusted() else {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.start()
            }
            return
        }
        let handler: (NSEvent) -> Void = { [weak self] event in self?.handle(event) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: {
            handler($0)
            return $0
        }) {
            monitors.append(local)
        }
        onListening()
    }

    /// A recording already running belongs to nobody's key, so it is treated as hands-free.
    func adoptRunningRecording() {
        if mode == .idle, daemonState() == "recording" { mode = .handsFree }
    }

    /// Voxtype stopped recording on its own, for example after a cancel from the command line.
    func daemonLeftRecording() {
        switch mode {
        case .handsFree, .stopArmed: mode = .idle
        case .holding where !pushToTalkDown: mode = .idle
        default: break
        }
    }

    func handle(_ event: NSEvent) {
        if event.type == .keyDown { return keyDown(event) }

        let handsFree = settings.handsFree.isDown(in: event.modifierFlags)
        if handsFree, !handsFreeDown {
            handsFreeDown = true
            if case .holding = mode { mode = .handsFree }
        } else if !handsFree {
            handsFreeDown = false
        }

        let pushToTalk = settings.pushToTalk.isDown(in: event.modifierFlags)
        if pushToTalk, !pushToTalkDown {
            pushToTalkDown = true
            pushToTalkPressed()
        } else if !pushToTalk, pushToTalkDown {
            pushToTalkDown = false
            pushToTalkReleased()
        }
    }

    private func pushToTalkPressed() {
        adoptRunningRecording()
        switch mode {
        case .idle:
            run("start")
            mode = handsFreeDown ? .handsFree : .holding(since: now())
        case .handsFree:
            mode = handsFreeDown ? .handsFree : .stopArmed
        case .holding, .stopArmed:
            break
        }
    }

    private func pushToTalkReleased() {
        switch mode {
        case .holding, .stopArmed:
            run("stop")
            mode = .idle
        case .idle, .handsFree:
            break
        }
    }

    private func keyDown(_ event: NSEvent) {
        let isCancel = settings.cancel.keyCode == event.keyCode
        switch mode {
        case .holding(let since):
            if isCancel {
                run("cancel")
                mode = .idle
            } else if now().timeIntervalSince(since) < Self.shortcutWindow {
                run("cancel")
                mode = .idle
                onShortcutAbort()
            }
        case .stopArmed:
            if isCancel {
                run("cancel")
                mode = .idle
            } else {
                mode = .handsFree
            }
        case .idle:
            if isCancel, daemonState() == "transcribing" { run("cancel") }
        case .handsFree:
            if isCancel {
                run("cancel")
                mode = .idle
            }
        }
    }
}

/// Runs `voxtype record <command>` in order, off the main thread.
final class VoxtypeCommand {
    /// Homebrew installs to /opt/homebrew on Apple silicon and /usr/local on Intel Macs.
    private static let executable = ["/opt/homebrew/bin/voxtype", "/usr/local/bin/voxtype"]
        .map(URL.init(fileURLWithPath:))
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        ?? URL(fileURLWithPath: "/opt/homebrew/bin/voxtype")
    private let queue = DispatchQueue(label: "voxtype-osd.record")

    func run(_ command: String) {
        queue.async {
            let process = Process()
            process.executableURL = Self.executable
            process.arguments = ["record", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                NSLog("VoxtypeOSD: voxtype record \(command) failed: \(error)")
            }
        }
    }
}

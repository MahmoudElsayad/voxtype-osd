import AppKit
import ApplicationServices
import os

/// Shows a small floating panel at the text caret while Voxtype records or transcribes.
///
/// Voxtype writes its state to `/tmp/voxtype/state` and streams microphone levels on
/// `/tmp/voxtype/audio.sock`. This app only reads them; it never controls Voxtype.
final class OverlayController: NSObject, NSApplicationDelegate {
    private static let stateFile = "/tmp/voxtype/state"
    private static let audioSocket = "/tmp/voxtype/audio.sock"
    private static let logFile = NSHomeDirectory() + "/Library/Logs/voxtype/stdout.log"
    private static let cancelledHold: TimeInterval = 1.2

    private let panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Theme.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }()
    private let view = OverlayView(frame: NSRect(origin: .zero, size: Theme.size))
    /// What the panel shows. It differs from `daemonState` while a cancelled run is held on screen.
    private var phase: Phase?
    private var daemonState: Phase?
    private var audio: AudioLevels?
    private let logWatch = LogWatch(path: OverlayController.logFile)
    private let history = History()
    private let rewrite = RewriteSwitch()
    private let settings = SettingsStore()
    private let rewriteLog = RewriteLog()
    private var historyPanel: HistoryPanel?
    private var pendingHide: DispatchWorkItem?
    private let hotkeys = Hotkeys()
    /// Set when the keys turned out to be a shortcut, so that cancel is not shown in red.
    private var quietCancel = false
    private var recordingStarted = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.contentView = view
        historyPanel = HistoryPanel(history: history, rewrite: rewrite, settings: settings)
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        Logger(subsystem: "io.github.mahmoudelsayad.voxtype-osd", category: "app").notice("accessibility trusted: \(trusted, privacy: .public)")

        audio = AudioLevels(path: Self.audioSocket) { [weak self] peak in
            DispatchQueue.main.async {
                guard self?.phase == .recording else { return }
                self?.view.push(peakDbfs: peak)
            }
        }
        audio?.start()

        hotkeys.onModeChange = { [weak self] mode in self?.view.handsFree = mode == .handsFree || mode == .stopArmed }
        hotkeys.onShortcutAbort = { [weak self] in self?.quietCancel = true }
        hotkeys.onListening = { Logger(subsystem: "io.github.mahmoudelsayad.voxtype-osd", category: "app").notice("hotkeys listening") }
        settings.observe { [weak self] in self?.hotkeys.settings = $0 }
        hotkeys.start()

        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        var cancelled = false
        for event in logWatch.poll() {
            switch event {
            case .cancelled: cancelled = true
            case .transcribed(let text):
                history.add(text)
                historyPanel?.historyChanged()
                // Voxtype stays in "transcribing" while the rewrite command runs.
                if rewrite.isOn, phase == .transcribing {
                    phase = .rewriting
                    view.phase = .rewriting
                }
            }
        }
        for text in rewriteLog.poll() {
            history.applyRewrite(text)
            historyPanel?.historyChanged()
        }
        let state = Self.readPhase()
        let changed = state != daemonState
        if daemonState == .recording, state != .recording { hotkeys.daemonLeftRecording() }
        if daemonState != .recording, state == .recording { hotkeys.adoptRunningRecording() }
        daemonState = state


        if cancelled, quietCancel {
            quietCancel = false
            transition(to: nil)
        } else if cancelled, panel.isVisible {
            showCancelled()
        } else if changed, phase != .cancelled || state == .recording {
            transition(to: state)
        }
        if phase == .recording { view.elapsed = Date().timeIntervalSince(recordingStarted) }
    }

    private static func readPhase() -> Phase? {
        let raw = (try? String(contentsOfFile: stateFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch raw {
        case "recording": return .recording
        case "transcribing": return .transcribing
        default: return nil
        }
    }

    private func transition(to next: Phase?) {
        pendingHide?.cancel()
        let wasHidden = phase == nil || phase == .cancelled
        phase = next
        guard let next else { return fade(to: 0) }

        view.phase = next
        if next == .recording {
            recordingStarted = Date()
            view.reset()
        }
        if wasHidden { show() }
    }

    /// Holds the red cancelled state on screen briefly, then fades out.
    private func showCancelled() {
        pendingHide?.cancel()
        phase = .cancelled
        view.phase = .cancelled
        fade(to: 1)

        let hide = DispatchWorkItem { [weak self] in
            guard let self, phase == .cancelled else { return }
            phase = nil
            fade(to: 0)
        }
        pendingHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cancelledHold, execute: hide)
    }

    private func show() {
        panel.setFrameOrigin(Anchor.panelOrigin(for: Anchor.current(), size: Theme.size))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        fade(to: 1)
    }

    private func fade(to alpha: CGFloat) {
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animate ? 0.15 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = alpha
        }, completionHandler: { [weak self] in
            if alpha == 0, self?.phase == nil { self?.panel.orderOut(nil) }
        })
    }
}

let app = NSApplication.shared
let controller = OverlayController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()

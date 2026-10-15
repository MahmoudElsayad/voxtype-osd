import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

func testRecordingCancellation() {
    func flags(_ raw: UInt) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                         modifierFlags: NSEvent.ModifierFlags(rawValue: raw), timestamp: 0,
                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: 54)!
    }
    func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: code)!
    }
    var commands: [String] = []
    let hotkeys = Hotkeys(run: { commands.append($0) })
    hotkeys.daemonState = { "idle" }

    // Both modifier orders enter hands-free and keep recording after release.
    for first in [UInt(0x0010), UInt(0x0040)] {
        commands = []
        hotkeys.handle(flags(first))
        hotkeys.handle(flags(0x0050))
        hotkeys.handle(flags(0))
        precondition(commands == ["start"] && hotkeys.mode == .handsFree)
        hotkeys.handle(key(0))
        precondition(commands == ["start"] && hotkeys.mode == .handsFree)
        hotkeys.handle(key(53))
        precondition(commands == ["start", "cancel"] && hotkeys.mode == .idle,
                     "Escape must cancel hands-free recording")
        hotkeys.handle(flags(0))
        precondition(commands == ["start", "cancel"])
    }

    // Cancellation while modifiers are held must not transcribe on release.
    commands = []
    hotkeys.handle(flags(0x0050))
    hotkeys.handle(key(53))
    hotkeys.handle(flags(0))
    precondition(commands == ["start", "cancel"] && hotkeys.mode == .idle)

    hotkeys.settings.cancel = .none
    commands = []
    hotkeys.handle(flags(0x0050))
    hotkeys.handle(flags(0))
    hotkeys.handle(key(53))
    precondition(commands == ["start"] && hotkeys.mode == .handsFree)
    hotkeys.daemonLeftRecording()
    hotkeys.settings.cancel = .escape

    // Existing cancellation paths remain available.
    commands = []
    hotkeys.handle(flags(0x0010))
    hotkeys.handle(key(53))
    hotkeys.handle(flags(0))
    precondition(commands == ["start", "cancel"] && hotkeys.mode == .idle)
    commands = []
    hotkeys.handle(flags(0x0050))
    hotkeys.handle(flags(0))
    hotkeys.handle(flags(0x0010))
    precondition(hotkeys.mode == .stopArmed)
    hotkeys.handle(key(53))
    hotkeys.handle(flags(0))
    precondition(commands == ["start", "cancel"] && hotkeys.mode == .idle)
    commands = []
    hotkeys.daemonState = { "transcribing" }
    hotkeys.handle(key(53))
    precondition(commands == ["cancel"] && hotkeys.mode == .idle)
    commands = []
    hotkeys.daemonState = { "recording" }
    hotkeys.adoptRunningRecording()
    hotkeys.handle(key(53))
    precondition(commands == ["cancel"] && hotkeys.mode == .idle)
    print("Hands-free recording and cancellation passed")
}
testRecordingCancellation()

func testRecordingMedia() throws {
    func item(playing: Bool = true, pid: Int = 42, id: String = "song-1") -> MediaSnapshot {
        let json = "{\"playing\":\(playing),\"processIdentifier\":\(pid),\"bundleIdentifier\":\"test.browser\",\"contentItemIdentifier\":\"\(id)\"}"
        return try! JSONDecoder().decode(MediaSnapshot.self, from: Data(json.utf8))
    }
    final class Player {
        var current: MediaSnapshot?
        var commands: [String] = []
        var succeeds = true
        var applies = true
        var ready = true
        var pending: [() -> Void] = []
        let queue = DispatchQueue(label: "media-test")
        lazy var media = RecordingMedia(queue: queue, snapshot: { self.current }, send: { command in
            self.commands.append(command)
            if self.succeeds, self.applies, let current = self.current {
                let json = "{\"playing\":\(command == "play"),\"processIdentifier\":\(current.processIdentifier),\"bundleIdentifier\":\"\(current.bundleIdentifier)\",\"contentItemIdentifier\":\"\(current.contentItemIdentifier!)\"}"
                self.current = try! JSONDecoder().decode(MediaSnapshot.self, from: Data(json.utf8))
            }
            return self.succeeds
        }, playbackReady: { self.ready }, schedule: { _, action in self.pending.append(action) })
        func recording(_ active: Bool) {
            media.setRecording(active)
            queue.sync {}
        }
        func advance() {
            let actions = pending
            pending = []
            actions.forEach { $0() }
            queue.sync {}
        }
    }
    let player = Player()
    player.current = item()
    player.recording(true)
    precondition(player.commands == ["pause"] && player.current?.playing == false)
    player.recording(false)
    precondition(player.commands == ["pause"], "Resume must wait for microphone release")
    player.advance()
    precondition(player.commands == ["pause", "play"])

    for initial in [nil, item(playing: false)] {
        let player = Player()
        player.current = initial
        player.recording(true)
        player.recording(false)
        player.advance()
        precondition(player.commands.isEmpty, "Leave absent and already paused media alone")
    }
    for changed in [item(playing: false, id: "song-2"), item(playing: false, pid: 99), item()] {
        let player = Player()
        player.current = item()
        player.recording(true)
        player.current = changed
        player.recording(false)
        player.advance()
        precondition(player.commands == ["pause"], "Do not resume changed or already playing media")
    }
    for commandSucceeded in [false, true] {
        let player = Player()
        player.current = item()
        player.succeeds = commandSucceeded
        player.applies = false
        player.recording(true)
        player.current = item(playing: false)
        player.recording(false)
        player.advance()
        precondition(player.commands == ["pause"], "An unconfirmed pause grants no resume ownership")
    }
    let restarted = Player()
    restarted.current = item()
    restarted.recording(true)
    restarted.recording(false)
    restarted.recording(true)
    restarted.advance()
    precondition(restarted.commands == ["pause"], "A stale timer must not resume during a new recording")
    restarted.recording(false)
    restarted.advance()
    precondition(restarted.commands == ["pause", "play"], "A new recording retains the pause it inherited")

    let transient = Player()
    transient.current = item()
    transient.recording(true)
    transient.recording(false)
    transient.current = nil
    transient.recording(true)
    transient.advance()
    transient.current = item(playing: false)
    transient.recording(false)
    transient.advance()
    precondition(transient.commands == ["pause", "play"], "Transient metadata failure must retain an owned pause")

    let delayedQueue = DispatchQueue(label: "media-delayed-test")
    var delayedSnapshots: [MediaSnapshot?] = [item(), nil, item(), item(playing: false)]
    var delayedCommands: [String] = []
    let delayed = RecordingMedia(queue: delayedQueue, snapshot: {
        delayedSnapshots.isEmpty ? item(playing: false) : delayedSnapshots.removeFirst()
    }, send: { delayedCommands.append($0); return true }, playbackReady: { true })
    delayed.setRecording(true)
    delayedQueue.sync {}
    delayed.restoreOnQuit()
    precondition(delayedCommands == ["pause", "play"], "Allow a dispatched pause to take effect before claiming ownership")

    let headset = Player()
    headset.current = item()
    headset.ready = false
    headset.recording(true)
    headset.recording(false)
    headset.advance()
    precondition(headset.commands == ["pause"], "Wait for Bluetooth output quality to recover")
    headset.ready = true
    headset.advance()
    precondition(headset.commands == ["pause", "play"])
    let unavailableOutput = Player()
    unavailableOutput.current = item()
    unavailableOutput.ready = false
    unavailableOutput.recording(true)
    unavailableOutput.recording(false)
    for _ in 0...25 { unavailableOutput.advance() }
    precondition(unavailableOutput.commands == ["pause", "play"], "Bound the wait for Bluetooth recovery")

    let quitting = Player()
    quitting.current = item()
    quitting.recording(true)
    quitting.media.restoreOnQuit()
    precondition(quitting.commands == ["pause", "play"])
    quitting.recording(false)
    quitting.advance()
    precondition(quitting.commands == ["pause", "play"], "Quit restoration must not resume twice")

    let fallback = try JSONDecoder().decode(MediaSnapshot.self, from: Data("{\"playing\":false,\"processIdentifier\":42,\"bundleIdentifier\":\"test.browser\",\"title\":\"A song\",\"duration\":123}".utf8))
    precondition(fallback.isSameSession(as: fallback))
    func browserItem(_ id: String, title: String) -> MediaSnapshot {
        let data = try! JSONSerialization.data(withJSONObject: ["playing": false, "processIdentifier": 42,
            "bundleIdentifier": "test.browser", "contentItemIdentifier": id, "title": title, "duration": 123])
        return try! JSONDecoder().decode(MediaSnapshot.self, from: data)
    }
    let browserVideo = browserItem("before-pause", title: "A video")
    precondition(browserVideo.isSameSession(as: browserItem("after-pause", title: "A video")),
                 "Browser item identifiers can change when the same video pauses")
    precondition(!browserVideo.isSameSession(as: browserItem("before-pause", title: "Another video")),
                 "Matching item identifiers must not override a changed video")
    let anonymous = try JSONDecoder().decode(MediaSnapshot.self, from: Data("{\"playing\":false,\"processIdentifier\":42,\"bundleIdentifier\":\"test.browser\"}".utf8))
    precondition(!anonymous.isSameSession(as: anonymous), "Do not guess when item identity is unavailable")
    print("Recording media pause, ownership, delayed resume, player changes, failures, restart, and quit passed")
}
try testRecordingMedia()

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxtype-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
precondition(old.rewriteProvider == .claude && old.rewriteModel == "claude-haiku-5-5")
let codex = try JSONDecoder().decode(Settings.self, from: Data("{\"rewriteProvider\":\"codex\",\"rewriteEffort\":\"ultra\"}".utf8))
precondition(codex.rewriteModel.isEmpty && codex.rewriteEffort == "ultra")
let fixture = """
{"fetchedAt":"2026-10-15T00:00:00Z","models":[{"slug":"gpt-6.1-sol","name":"GPT-6.1 Sol","efforts":["low","ultra"],"defaultEffort":"low"}]}
"""
try Data(fixture.utf8).write(to: directory.appendingPathComponent("codex-models.json"))
let store = SettingsStore(directory: directory)
let catalog = ModelCatalog(directory: directory)
precondition(catalog.codexModels.count == 1)
store.update { $0.rewriteEffort = "high" }
func card() -> SettingsCard {
    SettingsCard(store: store, catalog: catalog, width: 360, onDone: {}, onChange: {})
}
func choose(_ card: SettingsCard, label: String, title: String) {
    let chip = card.subviews.compactMap { $0 as? MenuChip }.first { $0.accessibilityLabel()?.hasPrefix(label) == true }!
    let menu = chip.makeMenu()
    let index = menu.items.firstIndex { $0.title == title }!
    menu.performActionForItem(at: index)
}
choose(card(), label: "REWRITE PROVIDER", title: "Codex")
precondition(store.settings.rewriteProvider == .codex)
precondition(store.settings.rewriteModel == "gpt-6.1-sol" && store.settings.rewriteEffort == nil)
choose(card(), label: "REWRITE EFFORT", title: "Ultra")
precondition(store.settings.rewriteEffort == "ultra")
let view = card()
let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = view
view.layoutSubtreeIfNeeded()
if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let screenshot = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/voxtype-codex-settings.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: screenshot))
    print("Settings screenshot: \(screenshot), size: \(view.frame.size)")
}
choose(card(), label: "REWRITE PROVIDER", title: "Claude Code")
precondition(store.settings.rewriteProvider == .claude && store.settings.rewriteEffort == nil)
precondition(store.settings.rewriteModel == catalog.models.first?.slug)
print("Settings decoding, cached discovery, provider reset, effort menus, and rendering passed")

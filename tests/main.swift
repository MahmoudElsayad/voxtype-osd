import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
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

import AppKit

/// A modifier key that can start a recording. Modifier keys report presses through
/// `flagsChanged` events, which carry the key code of the key that changed.
enum TriggerKey: String, Codable, CaseIterable {
    case rightCommand, leftCommand, rightOption, leftOption, rightControl, leftControl, rightShift, leftShift, fn

    var title: String {
        switch self {
        case .rightCommand: "Right Command"
        case .leftCommand: "Left Command"
        case .rightOption: "Right Option"
        case .leftOption: "Left Option"
        case .rightControl: "Right Control"
        case .leftControl: "Left Control"
        case .rightShift: "Right Shift"
        case .leftShift: "Left Shift"
        case .fn: "Fn (Globe)"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightCommand: 54
        case .leftCommand: 55
        case .leftShift: 56
        case .leftOption: 58
        case .leftControl: 59
        case .rightShift: 60
        case .rightOption: 61
        case .rightControl: 62
        case .fn: 63
        }
    }

    /// Whether the key is held, from the device-dependent bits (IOKit's NX_DEVICE*KEYMASK)
    /// that tell the left and right keys apart.
    func isDown(in flags: NSEvent.ModifierFlags) -> Bool {
        let raw = flags.rawValue
        switch self {
        case .leftControl: return raw & 0x0001 != 0
        case .leftShift: return raw & 0x0002 != 0
        case .rightShift: return raw & 0x0004 != 0
        case .leftCommand: return raw & 0x0008 != 0
        case .rightCommand: return raw & 0x0010 != 0
        case .leftOption: return raw & 0x0020 != 0
        case .rightOption: return raw & 0x0040 != 0
        case .rightControl: return raw & 0x2000 != 0
        case .fn: return flags.contains(.function)
        }
    }
}

enum CancelKey: String, Codable, CaseIterable {
    case escape, none

    var title: String {
        switch self {
        case .escape: "Escape"
        case .none: "None"
        }
    }

    var keyCode: UInt16? {
        switch self {
        case .escape: 53
        case .none: nil
        }
    }
}

/// The user's choices, saved as `settings.json` in `~/Library/Application Support/VoxtypeOSD`.
/// `rewrite/rewrite.py` reads `vocabulary`, `rewriteModel` and `rewriteEffort` from the same file.
struct Settings: Codable, Equatable {
    /// Hold to talk; release to transcribe.
    var pushToTalk: TriggerKey = .rightCommand
    /// Held together with the push-to-talk key, it starts hands-free recording.
    var handsFree: TriggerKey = .rightOption
    var cancel: CancelKey = .escape
    /// Names the rewrite should spell correctly, such as product names Whisper mishears.
    var vocabulary: [String] = Settings.defaultVocabulary
    var rewriteProvider: RewriteProvider = .claude
    /// The model for the rewrite, as a full model name such as "claude-haiku-5-5".
    var rewriteModel = "claude-haiku-5-5"
    /// A `claude --effort` level, or nil for the model's own default.
    var rewriteEffort: String?

    static let defaultVocabulary = [
        "Claude", "Claude Code", "Anthropic", "GitHub", "PR", "pull request", "GPT", "OpenAI",
        "Codex", "MCP", "API", "CLI", "TypeScript", "Swift", "macOS", "Voxtype",
    ]

    init() {}

    // Missing fields fall back to their defaults, so older or hand-edited files still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        pushToTalk = (try? container.decode(TriggerKey.self, forKey: .pushToTalk)) ?? defaults.pushToTalk
        handsFree = (try? container.decode(TriggerKey.self, forKey: .handsFree)) ?? defaults.handsFree
        cancel = (try? container.decode(CancelKey.self, forKey: .cancel)) ?? defaults.cancel
        vocabulary = (try? container.decode([String].self, forKey: .vocabulary)) ?? defaults.vocabulary
        rewriteProvider = (try? container.decode(RewriteProvider.self, forKey: .rewriteProvider)) ?? .claude
        rewriteModel = (try? container.decode(String.self, forKey: .rewriteModel)) ?? (rewriteProvider == .claude ? defaults.rewriteModel : "")
        rewriteEffort = (try? container.decodeIfPresent(String.self, forKey: .rewriteEffort))
            .flatMap { $0 }.flatMap { (rewriteProvider == .claude ? ModelCatalog.cliEfforts : ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]).contains($0) ? $0 : nil }
        if handsFree == pushToTalk { handsFree = defaults.handsFree == pushToTalk ? .leftOption : defaults.handsFree }
    }
}

/// Loads and saves `Settings`, and tells observers when they change.
final class SettingsStore {
    private(set) var settings: Settings
    private let url: URL
    private var observers: [(Settings) -> Void] = []

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoxtypeOSD"))
    {
        url = directory.appendingPathComponent("settings.json")
        settings = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        if !FileManager.default.fileExists(atPath: url.path) { save() }
    }

    func observe(_ observer: @escaping (Settings) -> Void) {
        observers.append(observer)
        observer(settings)
    }

    func update(_ change: (inout Settings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        save()
        observers.forEach { $0(next) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(settings).write(to: url, options: .atomic)
        } catch {
            NSLog("VoxtypeOSD: could not save settings: \(error)")
        }
    }
}

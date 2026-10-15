import Foundation

enum RewriteProvider: String, Codable, CaseIterable {
    case claude, codex
    var title: String { self == .claude ? "Claude Code" : "Codex" }
}

/// A model and its provider's supported reasoning levels.
struct RewriteModel: Codable, Equatable {
    let slug: String
    let name: String
    let efforts: [String]
    let defaultEffort: String?
}

/// The Claude models the installed Claude Code can run, from T3 Code's public model manifest.
///
/// Claude Code is used through a subscription login, so the Anthropic models API (which needs an
/// API key and lists no effort levels) is not an option. The manifest is fetched at most every
/// six hours and cached; without it, a built-in list is used.
final class ModelCatalog {
    static let manifestURL = URL(string:
        "https://raw.githubusercontent.com/pingdotgg/t3code/main/apps/server/src/provider/model-manifest.json")!
    static let maxAge: TimeInterval = 6 * 60 * 60
    /// The levels `claude --effort` accepts. Manifest options outside it, such as Ultrathink,
    /// are T3 Code prompt features, not CLI efforts.
    static let cliEfforts = ["low", "medium", "high", "xhigh", "max"]

    static let builtIn: [RewriteModel] = [
        RewriteModel(slug: "claude-haiku-5-5", name: "Claude Haiku 5.5", efforts: cliEfforts, defaultEffort: "medium"),
        RewriteModel(slug: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", efforts: cliEfforts, defaultEffort: "high"),
        RewriteModel(slug: "claude-opus-5-5", name: "Claude Opus 5.5", efforts: cliEfforts, defaultEffort: "medium"),
        RewriteModel(slug: "claude-fable-5-1", name: "Claude Fable 5.1", efforts: cliEfforts, defaultEffort: "medium"),
    ]

    private struct Cache: Codable {
        let fetchedAt: Date
        let models: [RewriteModel]
    }

    private(set) var models: [RewriteModel]
    private(set) var codexModels: [RewriteModel] = []
    private(set) var codexStatus = "Loading Codex models"
    private var codexFetchedAt: Date?
    private var refreshingCodex = false
    private let codexCacheURL: URL
    private let cacheURL: URL
    private var fetchedAt: Date?

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoxtypeOSD"))
    {
        cacheURL = directory.appendingPathComponent("models.json")
        codexCacheURL = directory.appendingPathComponent("codex-models.json")
        if let data = try? Data(contentsOf: codexCacheURL),
           let cache = try? JSONDecoder.iso8601.decode(Cache.self, from: data), !cache.models.isEmpty {
            codexModels = cache.models
            codexFetchedAt = cache.fetchedAt
            codexStatus = "Uses your Codex login"
        }
        let cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder.iso8601.decode(Cache.self, from: $0) }
        models = cache?.models.isEmpty == false ? cache!.models : Self.builtIn
        fetchedAt = cache?.fetchedAt
    }

    func models(for provider: RewriteProvider) -> [RewriteModel] {
        provider == .claude ? models : codexModels
    }

    func model(_ slug: String, provider: RewriteProvider = .claude) -> RewriteModel? {
        models(for: provider).first { $0.slug == slug }
    }

    /// Runs off the main thread. The helper bounds its child process to eight seconds.
    func refreshCodexIfStale(now: Date = Date(), completion: @escaping () -> Void) {
        guard !refreshingCodex else { return }
        if let codexFetchedAt, now.timeIntervalSince(codexFetchedAt) < Self.maxAge { return }
        refreshingCodex = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let helper = Bundle.main.resourceURL?.appendingPathComponent("codex_models.py")
            let data = helper.flatMap { BoundedCommand.run("/usr/bin/python3", arguments: [$0.path], timeout: 10) }
            let parsed = data.flatMap { try? JSONDecoder().decode([RewriteModel].self, from: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshingCodex = false
                if let parsed, !parsed.isEmpty {
                    self.codexModels = parsed
                    self.codexFetchedAt = now
                    self.codexStatus = "Uses your Codex login"
                    if let data = try? JSONEncoder.iso8601.encode(Cache(fetchedAt: now, models: parsed)) {
                        try? FileManager.default.createDirectory(at: self.codexCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? data.write(to: self.codexCacheURL, options: .atomic)
                    }
                } else {
                    self.codexStatus = self.codexModels.isEmpty ? "Codex unavailable. Install and sign in" : "Cached models. Codex refresh failed"
                }
                completion()
            }
        }
    }

    /// Fetches the manifest when the cache is older than six hours. `completion` runs on the
    /// main thread, only when the list changed.
    func refreshIfStale(now: Date = Date(), completion: @escaping () -> Void) {
        if let fetchedAt, now.timeIntervalSince(fetchedAt) < Self.maxAge { return }
        URLSession.shared.dataTask(with: Self.manifestURL) { [weak self] data, _, _ in
            guard let data, let parsed = Self.parse(manifest: data, claudeVersion: ClaudeCLI.version()),
                  !parsed.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = parsed != self.models
                self.models = parsed
                self.fetchedAt = now
                self.save()
                if changed { completion() }
            }
        }.resume()
    }

    /// Current Claude models from the manifest that `claudeVersion` (when known) can run.
    static func parse(manifest data: Data, claudeVersion: String?) -> [RewriteModel]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [String: Any],
              let claude = providers["claudeAgent"] as? [String: Any],
              let entries = claude["models"] as? [[String: Any]]
        else { return nil }
        let profiles = claude["profiles"] as? [String: Any] ?? [:]

        return entries.compactMap { entry in
            guard entry["status"] as? String == "current",
                  let slug = entry["slug"] as? String, let name = entry["name"] as? String
            else { return nil }
            let minVersion = ((entry["adapter"] as? [String: Any])?["claudeCode"] as? [String: Any])?["minVersion"] as? String
            if let claudeVersion, let minVersion, compare(claudeVersion, minVersion) == .orderedAscending { return nil }

            let profile = (entry["profile"] as? String).flatMap { profiles[$0] as? [String: Any] }
            let descriptors = (profile?["capabilities"] as? [String: Any])?["optionDescriptors"] as? [[String: Any]] ?? []
            let options = descriptors.first { $0["id"] as? String == "effort" }?["options"] as? [[String: Any]] ?? []
            let efforts = options.compactMap { $0["id"] as? String }.filter(cliEfforts.contains)
            let defaultEffort = options.first { $0["isDefault"] as? Bool == true }?["id"] as? String
            return RewriteModel(slug: slug, name: name, efforts: efforts,
                               defaultEffort: efforts.contains(defaultEffort ?? "") ? defaultEffort : nil)
        }
        .sorted { rank($0.slug) < rank($1.slug) }
    }

    /// Fastest first: the rewrite runs on every dictation, so latency matters most.
    private static func rank(_ slug: String) -> Int {
        ["haiku", "sonnet", "opus", "fable"].firstIndex { slug.contains($0) } ?? 99
    }

    /// Compares dotted version numbers such as 2.1.300 and 2.1.284.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private func save() {
        guard let fetchedAt, let data = try? JSONEncoder.iso8601.encode(Cache(fetchedAt: fetchedAt, models: models))
        else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

/// The installed Claude Code CLI. Apps launched from Finder get a minimal PATH, so the usual
/// install locations are checked directly.
enum ClaudeCLI {
    static let path: String? = [
        NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// The version from `claude --version`, such as "2.1.300", or nil when it cannot run.
    static func version() -> String? {
        guard let path else { return nil }
        guard let data = BoundedCommand.run(path, arguments: ["--version"], timeout: 2) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: " ").first.map(String.init)
    }
}

extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// Temporary files avoid pipe backpressure; a deadline bounds CLI startup.
enum BoundedCommand {
    static func run(_ path: String, arguments: [String], timeout: TimeInterval) -> Data? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let output = try? FileHandle(forWritingTo: url) else { return nil }
        defer { try? output.close(); try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return nil }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: url)
    }
}

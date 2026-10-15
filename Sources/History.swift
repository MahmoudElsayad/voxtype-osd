import Foundation

struct Transcription: Codable, Equatable {
    let date: Date
    /// The final text: Claude's rewrite when one was made, otherwise the transcription.
    var text: String
    /// The transcription before Claude rewrote it, or nil when it was not rewritten.
    var original: String?
}

/// Recent transcriptions, newest first, saved to `~/Library/Application Support/VoxtypeOSD`.
final class History {
    static let limit = 200

    private(set) var entries: [Transcription]
    private let url: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoxtypeOSD"))
    {
        url = directory.appendingPathComponent("history.json")
        let data = try? Data(contentsOf: url)
        entries = data.flatMap { try? Self.decoder.decode([Transcription].self, from: $0) } ?? []
    }

    func add(_ text: String, at date: Date = Date()) {
        entries.insert(Transcription(date: date, text: text), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    /// Attaches a rewrite to the newest entry, if that entry is recent and not rewritten yet.
    /// Voxtype runs the rewrite right after it logs the transcription, so the newest entry is it.
    func applyRewrite(_ text: String, now: Date = Date()) {
        guard let newest = entries.first, newest.original == nil,
              now.timeIntervalSince(newest.date) < 120, text != newest.text else { return }
        entries[0].original = newest.text
        entries[0].text = text
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(entries).write(to: url, options: .atomic)
        } catch {
            NSLog("VoxtypeOSD: could not save history: \(error)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

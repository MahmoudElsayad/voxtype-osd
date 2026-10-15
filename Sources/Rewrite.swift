import Foundation

/// The on/off switch for the rewrite. `rewrite/voxtype-rewrite` checks for the same file.
final class RewriteSwitch {
    private let flag: String

    init(directory: String = NSHomeDirectory() + "/Library/Application Support/VoxtypeOSD") {
        flag = directory + "/rewrite-enabled"
    }

    var isOn: Bool {
        get { FileManager.default.fileExists(atPath: flag) }
        set {
            if newValue {
                try? FileManager.default.createDirectory(
                    atPath: (flag as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: flag, contents: nil)
            } else {
                try? FileManager.default.removeItem(atPath: flag)
            }
        }
    }
}

/// Follows `rewrites.jsonl`, where `rewrite/rewrite.py` appends one record per rewrite.
final class RewriteLog {
    private struct Record: Decodable {
        let text: String
        let ok: Bool
    }

    private let path: String
    private var offset: UInt64

    init(directory: String = NSHomeDirectory() + "/Library/Application Support/VoxtypeOSD") {
        path = directory + "/rewrites.jsonl"
        offset = Self.size(of: path)
    }

    /// The texts of successful rewrites appended since the last call, oldest first.
    func poll() -> [String] {
        let size = Self.size(of: path)
        if size < offset { offset = 0 }
        guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        offset += UInt64(lastNewline + 1)

        return data[...lastNewline].split(separator: UInt8(ascii: "\n")).compactMap {
            guard let record = try? JSONDecoder().decode(Record.self, from: Data($0)), record.ok else { return nil }
            return record.text
        }
    }

    private static func size(of path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}

import Foundation

enum LogEvent: Equatable {
    case cancelled
    case transcribed(String)
}

/// Follows the Voxtype daemon's log for the two events that its state file does not carry.
///
/// The state file says `idle` both after a finished run and after a cancelled one, and it never
/// holds the text. Voxtype.app writes the log to `~/Library/Logs/voxtype` and starts it afresh on
/// every launch. The daemon logs "Recording cancelled", "Transcription cancelled" or "Streaming
/// cancelled" (optionally followed by "via hotkey"), and `Transcribed: {:?}` with the raw text.
final class LogWatch {
    private let path: String
    private var file: (id: UInt64, offset: UInt64)
    private var partialLine = Data()

    init(path: String) {
        self.path = path
        file = Self.identity(of: path)
    }

    /// The events appended since the last call, oldest first.
    func poll() -> [LogEvent] {
        let current = Self.identity(of: path)
        if current.id != file.id || current.offset < file.offset {
            file = (current.id, 0)
            partialLine.removeAll()
        }
        guard current.offset > file.offset, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        try? handle.seek(toOffset: file.offset)
        let data = (try? handle.readToEnd()) ?? Data()
        file.offset += UInt64(data.count)

        partialLine.append(data)
        guard let lastNewline = partialLine.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = partialLine[..<lastNewline]
        partialLine = Data(partialLine[partialLine.index(after: lastNewline)...])

        return String(decoding: complete, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { Self.event(in: String($0)) }
    }

    static func event(in line: String) -> LogEvent? {
        if let marker = line.range(of: "Transcribed: \"") {
            let quoted = line[marker.upperBound...]
            guard let end = quoted.lastIndex(of: "\"") else { return nil }
            let text = unescapeRustDebug(String(quoted[..<end]))
            return text.isEmpty ? nil : .transcribed(text)
        }
        if line.range(of: #"(Recording|Transcription|Streaming) cancelled"#, options: .regularExpression) != nil {
            return .cancelled
        }
        return nil
    }

    /// Reverses Rust's `{:?}` escaping of a string: `\"`, `\\`, `\n`, `\r`, `\t`, `\0`, `\'` and `\u{…}`.
    static func unescapeRustDebug(_ escaped: String) -> String {
        var result = ""
        var characters = escaped.makeIterator()
        while let character = characters.next() {
            guard character == "\\", let code = characters.next() else {
                result.append(character)
                continue
            }
            switch code {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "0": result.append("\0")
            case "u":
                guard characters.next() == "{" else { continue }
                var hex = ""
                while let digit = characters.next(), digit != "}" { hex.append(digit) }
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                    result.unicodeScalars.append(scalar)
                }
            default: result.append(code)
            }
        }
        return result
    }

    private static func identity(of path: String) -> (id: UInt64, offset: UInt64) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let id = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        return (id, size)
    }
}

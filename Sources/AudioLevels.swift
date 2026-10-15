import Foundation

/// Reads the level frames that the Voxtype daemon publishes for its on-screen display.
///
/// Each frame is 16 bytes in native byte order: `seq: u32, min: f32, max: f32, peak_dbfs: f32`,
/// sent 100 times a second while recording. See `src/audio/levels.rs` in the Voxtype repository.
final class AudioLevels {
    private let path: String
    private let onPeak: (Float) -> Void

    init(path: String, onPeak: @escaping (Float) -> Void) {
        self.path = path
        self.onPeak = onPeak
    }

    func start() {
        let thread = Thread { self.run() }
        thread.name = "voxtype-osd.audio"
        thread.start()
    }

    private func run() {
        while true {
            readUntilClosed()
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func readUntilClosed() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return }

        var frame = [UInt8](repeating: 0, count: 16)
        while readExactly(fd, &frame) {
            let peak = frame.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Float.self) }
            onPeak(peak)
        }
    }

    private func readExactly(_ fd: Int32, _ buffer: inout [UInt8]) -> Bool {
        var filled = 0
        while filled < buffer.count {
            let count = buffer.withUnsafeMutableBytes {
                read(fd, $0.baseAddress! + filled, $0.count - filled)
            }
            if count <= 0 { return false }
            filled += count
        }
        return true
    }
}

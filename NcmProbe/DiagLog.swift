import Foundation

/// Appends timestamped diagnostic lines to Documents/ncmprobe_diag.log so the
/// user can share the whole file instead of screenshotting the UI. All writes
/// are serialized on a dedicated queue.
///
/// Levels (mirrors DiPlay's NPVS-* scheme for side-by-side comparison):
///   EVT   state transitions (connect/ready/config/reconnect)
///   STAT  a 5-second heartbeat with windowed counters
///   WARN  silent drops, stalls, failures, swallowed errors
final class DiagLog {
    static let shared = DiagLog()
    private let queue = DispatchQueue(label: "ncmprobe.diaglog")
    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ncmprobe_diag.log")
    }()
    // Bound the file so a long-running session cannot grow it without limit.
    private let maxBytes = 2 * 1024 * 1024

    private init() {}

    func line(_ message: String) { write(message) }
    func evt(_ message: String) { write("EVT  " + message) }
    func stat(_ message: String) { write("STAT " + message) }
    func warn(_ message: String) { write("WARN " + message) }

    private func write(_ message: String) {
        queue.async {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss.SSS"
            let stamp = df.string(from: Date())
            let text = "[\(stamp)] \(message)\n"
            guard let data = text.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let size = try? self.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > self.maxBytes {
                try? fm.removeItem(at: self.fileURL)
            }
            if fm.fileExists(atPath: self.fileURL.path),
               let handle = FileHandle(forWritingAtPath: self.fileURL.path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    func reset() { queue.async { try? FileManager.default.removeItem(at: self.fileURL) } }

    func shareURL() -> URL { fileURL }
}

import Foundation

/// Appends timestamped diagnostic lines to Documents/ncmprobe_diag.log so the
/// user can share the whole file instead of screenshotting the UI. All writes
/// are serialized on a dedicated queue and use fileAppend for durability.
final class DiagLog {
    static let shared = DiagLog()
    private let queue = DispatchQueue(label: "ncmprobe.diaglog")
    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ncmprobe_diag.log")
    }()

    private init() {}

    func line(_ message: String) {
        queue.async {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss.SSS"
            let stamp = df.string(from: Date())
            let text = "[\(stamp)] \(message)\n"
            guard let data = text.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: self.fileURL.path),
               let handle = FileHandle(forWritingAtPath: self.fileURL.path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: self.fileURL, options: .atomic)
            }
        }
    }

    func reset() {
        queue.async { try? FileManager.default.removeItem(at: self.fileURL) }
    }

    func shareURL() -> URL { fileURL }
}

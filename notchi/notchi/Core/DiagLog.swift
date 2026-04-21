import Foundation
import os.log

extension Duration {
    /// Milliseconds as an integer, for compact logging.
    nonisolated var ms: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}

/// Diagnostic file logger for debugging.
/// Writes to ~/Library/Logs/rhythm-diag.log in DEBUG builds only.
/// In release builds, write() is a no-op — use os.log Logger for production metrics.
@MainActor
final class DiagLog {
    static let shared = DiagLog()

    #if DEBUG
    private let fileHandle: FileHandle?

    private init() {
        let logPath = NSHomeDirectory() + "/Library/Logs/rhythm-diag.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: logPath)
        fileHandle?.seekToEndOfFile()
        write("=== Rhythm launched at \(ISO8601DateFormatter().string(from: Date())) ===")
    }

    func write(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            fileHandle?.write(data)
        }
        os_log(.debug, "[DIAG] %{public}@", message)
    }

    deinit {
        fileHandle?.closeFile()
    }
    #else
    private init() {}
    @inline(__always) func write(_ message: String) {}
    #endif
}

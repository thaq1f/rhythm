import Foundation
import os.log

/// Diagnostic file logger for debugging.
/// Writes to ~/Library/Logs/notchi-diag.log so events are always visible.
@MainActor
final class DiagLog {
    static let shared = DiagLog()
    private let fileHandle: FileHandle?
    private let logPath: String

    private init() {
        logPath = NSHomeDirectory() + "/Library/Logs/notchi-diag.log"
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
        // Also log at .error level so it shows in `log show`
        os_log(.error, "[DIAG] %{public}@", message)
    }

    deinit {
        fileHandle?.closeFile()
    }
}

import Foundation
import os.log

private nonisolated(unsafe) let logger = Logger(subsystem: "com.ruban.notchi", category: "TTYInput")

/// Injects text into a terminal tty using TIOCSTI via a Perl subprocess.
///
/// The subprocess calls setsid() to acquire the target tty as its controlling
/// terminal, which satisfies the BSD permission check for TIOCSTI without root.
final class TTYInputService {
    static let shared = TTYInputService()
    private init() {}

    // TIOCSTI on macOS: _IOW('t', 114, char) = 0x80017472
    private nonisolated(unsafe) static let perlScript = """
use POSIX 'setsid';
setsid();
open(my $tty, '+<', $ARGV[0]) or die "open $ARGV[0]: $!\\n";
my $TIOCSTI = 0x80017472;
while (read(STDIN, my $c, 1)) {
    ioctl($tty, $TIOCSTI, $c) or die "ioctl: $!\\n";
}
"""

    /// Injects `text` followed by a newline into `ttyPath`.
    /// Runs off the main thread. Returns true on success.
    func injectText(_ text: String, into ttyPath: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = ["-e", TTYInputService.perlScript, "--", ttyPath]

            let stdinPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                logger.error("Failed to launch perl: \(error)")
                return false
            }

            let inputBytes = (text + "\n").data(using: .utf8) ?? Data()
            stdinPipe.fileHandleForWriting.write(inputBytes)
            stdinPipe.fileHandleForWriting.closeFile()

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                logger.error("TTY injection failed (exit \(process.terminationStatus)): \(errMsg)")
                return false
            }

            logger.info("Injected \(text.count) chars into \(ttyPath)")
            return true
        }.value
    }

    /// Looks up the tty path for a running process via `ps`.
    /// Returns e.g. "/dev/ttys003", or nil if not attached to a tty.
    static func lookupTTY(for pid: Int) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", "tty="]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, raw != "??", raw != "?" else { return nil }
        return "/dev/" + raw
    }
}

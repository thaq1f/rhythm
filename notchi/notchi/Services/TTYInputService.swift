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
        // Race the injection against a 6-second timeout so a stalled IOCTL never hangs the UI.
        await withTaskGroup(of: Bool.self) { group in
            group.addTask(priority: .userInitiated) {
                await Task.detached(priority: .userInitiated) {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
                    process.arguments = ["-e", TTYInputService.perlScript, "--", ttyPath]

                    let stdinPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardInput = stdinPipe
                    process.standardError = stderrPipe

                    do { try process.run() } catch {
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
            group.addTask {
                // Timeout sentinel — kill the process and return failure after 6s.
                try? await Task.sleep(for: .seconds(6))
                DiagLog.shared.write("VOICE: TTY injection timed out after 6s")
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
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

    /// Scans all processes for a running `claude` instance with a controlling tty.
    /// Used as a last resort when the session has no stored tty and the pid is dead.
    /// Returns the first matching tty, preferring processes in `cwd` if provided.
    static func findClaudeTTY(preferringCWD cwd: String? = nil) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["axo", "pid=,tty=,command="]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        var candidates: [(tty: String, pid: String)] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count >= 3 else { continue }
            let pid = String(parts[0])
            let tty = String(parts[1])
            let cmd = String(parts[2])
            guard tty != "??", tty != "?", cmd.contains("claude") else { continue }
            let isNonInteractive = cmd.contains("--print") || cmd.contains(" -p ") || cmd.contains(" -p\t")
            guard !isNonInteractive else { continue }
            candidates.append((tty: "/dev/" + tty, pid: pid))
        }

        guard !candidates.isEmpty else { return nil }

        // If a preferred cwd is given, try to match via lsof
        if let cwd, !candidates.isEmpty {
            for c in candidates {
                let lsof = Process()
                lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                lsof.arguments = ["-p", c.pid, "-a", "-d", "cwd", "-Fn"]
                let lout = Pipe()
                lsof.standardOutput = lout
                lsof.standardError = Pipe()
                if (try? lsof.run()) != nil {
                    lsof.waitUntilExit()
                    let loutput = String(data: lout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if loutput.contains(cwd) { return c.tty }
                }
            }
        }

        return candidates.first?.tty
    }

}

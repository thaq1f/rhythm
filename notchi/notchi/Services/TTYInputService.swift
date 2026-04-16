import Foundation
import AppKit
import os.log

private nonisolated(unsafe) let logger = Logger(subsystem: "com.ruban.rhythm", category: "TTYInput")

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
    /// Scans all processes for an interactive `claude` instance with a controlling tty.
    /// Avoids lsof (can hang) — uses only `ps` which is safe and fast.
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

        var first: String?
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count >= 3 else { continue }
            let tty = String(parts[1])
            let cmd = String(parts[2])
            guard tty != "??", tty != "?", cmd.contains("claude") else { continue }
            let isNonInteractive = cmd.contains("--print") || cmd.contains(" -p ")
            guard !isNonInteractive else { continue }
            // Prefer a process whose command line mentions the preferred cwd
            let ttyPath = "/dev/" + tty
            if let cwd, cmd.contains(cwd) { return ttyPath }
            if first == nil { first = ttyPath }
        }
        return first
    }


    /// Finds the terminal app that owns a Claude Code process and activates
    /// the correct tab/window for the session.
    /// - Parameters:
    ///   - pid: The Claude Code process PID
    ///   - cwd: The session's working directory (used to match tab titles)
    /// - Returns: The terminal NSRunningApplication if found
    static func findAndActivateTerminal(for pid: Int, cwd: String) -> NSRunningApplication? {
        let knownTerminals: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2",
            "dev.warp.Warp-Stable", "com.warp.Warp",
            "net.kovidgoyal.kitty", "com.github.alacritty",
            "co.zeit.hyper", "com.mitchellh.ghostty",
        ]
        let knownNames: Set<String> = [
            "terminal", "iterm2", "iterm", "warp", "kitty",
            "alacritty", "hyper", "ghostty",
        ]

        // Walk up the process tree: claude → shell → terminal
        var current = pid
        var termApp: NSRunningApplication?
        for _ in 0..<5 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/ps")
            proc.arguments = ["-o", "ppid=", "-p", "\(current)"]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            guard (try? proc.run()) != nil else { break }
            proc.waitUntilExit()
            let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let ppid = Int(raw), ppid > 1 else { break }
            current = ppid

            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.processIdentifier == Int32(current) &&
                (knownTerminals.contains($0.bundleIdentifier ?? "") ||
                 knownNames.contains($0.localizedName?.lowercased() ?? ""))
            }) {
                termApp = app
                break
            }
        }

        guard let app = termApp else { return nil }

        // Try to switch to the right tab/window using Accessibility.
        let projectName = (cwd as NSString).lastPathComponent
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        switchToTab(matching: projectName, in: appElement)

        return app
    }

    /// Searches the AX tree for a tab group and clicks the tab whose title
    /// contains `text`. Works for Ghostty (AXRadioButton in AXTabGroup),
    /// Terminal.app, iTerm2, and most terminal emulators.
    private static func switchToTab(matching text: String, in element: AXUIElement, depth: Int = 0) {
        guard depth < 6 else { return }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        // Look for tab-like elements (AXRadioButton in tab bars, AXButton in tab bars)
        if role == kAXRadioButtonRole as String || role == kAXButtonRole as String {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String) ?? ""
            if title.localizedCaseInsensitiveContains(text) {
                AXUIElementPerformAction(element, kAXPressAction as CFString)
                DiagLog.shared.write("TERMINAL: Switched to tab '\(title)' (matched '\(text)')")
                return
            }
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return }
        for child in children { switchToTab(matching: text, in: child, depth: depth + 1) }
    }

}

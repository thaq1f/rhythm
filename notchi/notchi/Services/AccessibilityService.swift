import AppKit
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "Accessibility")

@MainActor
@Observable
final class AccessibilityService {
    static let shared = AccessibilityService()

    private(set) var isGranted = false
    private var pollTask: Task<Void, Never>?

    private init() {
        isGranted = AXIsProcessTrusted()
    }

    func checkPermission() {
        isGranted = AXIsProcessTrusted()
        DiagLog.shared.write("ACCESSIBILITY: isGranted=\(isGranted)")
    }

    /// Prompt for accessibility only if not already granted. Called on app launch.
    func requestPermissionIfNeeded() {
        isGranted = AXIsProcessTrusted()
        DiagLog.shared.write("ACCESSIBILITY: isGranted=\(isGranted)")
        if !isGranted {
            requestPermission()
        }
    }

    /// Registers the app in the Accessibility list and opens System Settings to the right pane.
    func requestPermission() {
        DiagLog.shared.write("ACCESSIBILITY: Requesting permission")

        // Step 1: Register the app in the Accessibility list (adds it if not present)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        // Step 2: Also open the exact settings pane directly (in case the dialog was suppressed)
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
                DiagLog.shared.write("ACCESSIBILITY: Opened System Settings → Accessibility")
            }
        }

        // Step 3: Poll until user toggles it on
        pollTask?.cancel()
        pollTask = Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                if AXIsProcessTrusted() {
                    isGranted = true
                    DiagLog.shared.write("ACCESSIBILITY: Permission granted — restarting key listener")
                    VoiceKeyListener.shared.recheckAccessibility()
                    return
                }
            }
            DiagLog.shared.write("ACCESSIBILITY: Permission poll timed out (2 min)")
        }
    }

    /// Copies text and sends Cmd+V followed by Return to the frontmost app.
    /// Used for non-interactive sessions (e.g. Conductor) where the chat input is active.
    func pasteTextAndReturn(_ text: String) {
        guard isGranted else { requestPermission(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            let vKey: CGKeyCode = 9    // V
            let retKey: CGKeyCode = 36 // Return
            func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
                guard let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
                e.flags = flags
                e.post(tap: .cghidEventTap)
            }
            post(vKey, down: true,  flags: .maskCommand)
            post(vKey, down: false, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(80))
            post(retKey, down: true)
            post(retKey, down: false)
            DiagLog.shared.write("ACCESSIBILITY: Pasted \(text.count) chars + Return to frontmost app")
        }
    }

    /// Copies text to clipboard and simulates Cmd+V in the frontmost app.
    func pasteText(_ text: String) {
        guard isGranted else {
            requestPermission()
            return
        }

        // Copy to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Small delay to ensure clipboard is ready
        Task {
            try? await Task.sleep(for: .milliseconds(50))

            // Simulate Cmd+V: keycode 9 = V key
            let vKeyCode: CGKeyCode = 9

            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) else {
                DiagLog.shared.write("ACCESSIBILITY: Failed to create CGEvent for paste")
                return
            }

            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            DiagLog.shared.write("ACCESSIBILITY: Pasted \(text.count) chars via Cmd+V")
        }
    }
}

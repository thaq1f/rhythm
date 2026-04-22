import AppKit
import os.log

private let logger = Logger(subsystem: "com.silca.rhythm", category: "Accessibility")

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

    /// Traverses the accessibility tree of `app` and clicks the first actionable
    /// element whose title or description contains `workspaceName`.
    /// Used to switch Conductor (or any multi-tab host) to the correct workspace
    /// before pasting a voice transcript.
    func navigateToWorkspace(_ workspaceName: String, in app: NSRunningApplication) -> Bool {
        guard isGranted else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let found = clickFirstMatch(text: workspaceName, in: appElement, depth: 0)
        if !found {
            // Dump matching elements so we can identify the right one.
            dumpMatchingElements(text: workspaceName, in: appElement, depth: 0)
        }
        DiagLog.shared.write("ACCESSIBILITY: navigateToWorkspace('\(workspaceName)') -> \(found ? "clicked" : "not found")")
        return found
    }

    /// Allowed roles for workspace navigation clicks.
    /// File browser icons, images, and static text are excluded to avoid
    /// opening Finder or triggering the wrong element.
    private static let clickableRoles: Set<String> = [
        kAXButtonRole as String,
        kAXCellRole as String,
        kAXMenuItemRole as String,
        "AXLink",
        "AXTabGroup",
        "AXTab",
        "AXRadioButton",
    ]

    private func clickFirstMatch(text: String, in element: AXUIElement, depth: Int) -> Bool {
        guard depth < 10 else { return false }

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? ""

        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
        let desc = (descRef as? String) ?? ""

        let matches = title.localizedCaseInsensitiveContains(text) ||
                      desc.localizedCaseInsensitiveContains(text)

        if matches {
            // Only click UI controls — skip file browser icons, images, static text.
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? ""
            let titleLower = title.lowercased()
            let isFileIcon = titleLower.contains("icon") || titleLower.contains("finder")

            if Self.clickableRoles.contains(role) && !isFileIcon {
                var actionNames: CFArray?
                AXUIElementCopyActionNames(element, &actionNames)
                let actionList = (actionNames as? [String]) ?? []
                if actionList.contains(kAXPressAction as String) {
                    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                    if result == .success {
                        DiagLog.shared.write("ACCESSIBILITY: Clicked \(role) '\(title)' (depth=\(depth))")
                        return true
                    }
                }
            }
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return false }
        for child in children {
            if clickFirstMatch(text: text, in: child, depth: depth + 1) { return true }
        }
        return false
    }

    private func dumpMatchingElements(text: String, in element: AXUIElement, depth: Int) {
        guard depth < 6 else { return }
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? ""
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""
        if title.localizedCaseInsensitiveContains(text) {
            DiagLog.shared.write("ACCESSIBILITY: candidate — role=\(role) title='\(title)' depth=\(depth)")
        }
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return }
        for child in children { dumpMatchingElements(text: text, in: child, depth: depth + 1) }
    }

    /// Finds the "Terminal input" text area in Conductor and focuses it.
    /// Returns true if focused successfully.
    func focusConductorInput(in app: NSRunningApplication) -> Bool {
        guard isGranted else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let textArea = findElementByDescription("Terminal input", role: "AXTextArea", in: appElement, depth: 0) else {
            DiagLog.shared.write("ACCESSIBILITY: Could not find Terminal input in Conductor")
            return false
        }
        // Focus the text area so keyboard events and paste go to it.
        let result = AXUIElementSetAttributeValue(textArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        DiagLog.shared.write("ACCESSIBILITY: Focused Terminal input (result=\(result == .success))")
        return result == .success
    }

    private func findElementByDescription(_ desc: String, role: String, in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 10 else { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let elemRole = (roleRef as? String) ?? ""
        if elemRole == "AXMenuBar" { return nil }

        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
        let elemDesc = (descRef as? String) ?? ""

        if elemRole == role && elemDesc.localizedCaseInsensitiveContains(desc) {
            return element
        }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findElementByDescription(desc, role: role, in: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    /// Copies text and sends Cmd+V followed by Return to a specific target app.
    /// Pass targetApp explicitly — never relies on "frontmost" to avoid routing to
    /// unrelated apps (Telegram, Safari, etc.) that happened to be focused before
    /// the user hovered the notch.
    func pasteTextAndReturn(_ text: String, targetApp: NSRunningApplication?) {
        guard isGranted else {
            DiagLog.shared.write("ACCESSIBILITY: ❌ pasteAndReturn skipped — no accessibility permission")
            requestPermission()
            return
        }
        let targetName = targetApp?.localizedName ?? targetApp?.bundleIdentifier ?? "unknown"
        let isActive = targetApp?.isActive ?? false
        let isTerminated = targetApp?.isTerminated ?? true
        DiagLog.shared.write("ACCESSIBILITY: pasteAndReturn — target=\(targetName), active=\(isActive), terminated=\(isTerminated), textLen=\(text.count)")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        Task { @MainActor in
            // Activate the specific app so its window becomes key before we paste.
            targetApp?.activate(options: .activateIgnoringOtherApps)
            try? await Task.sleep(for: .milliseconds(150))

            let isNowActive = targetApp?.isActive ?? false
            DiagLog.shared.write("ACCESSIBILITY: Pre-paste — target isActive=\(isNowActive)")

            let vKey: CGKeyCode = 9    // V
            let retKey: CGKeyCode = 36 // Return
            func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
                guard let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
                e.flags = flags
                e.post(tap: .cghidEventTap)
            }
            post(vKey, down: true,  flags: .maskCommand)
            post(vKey, down: false, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(100))
            post(retKey, down: true)
            post(retKey, down: false)
            let clipboardContent = NSPasteboard.general.string(forType: .string)
            DiagLog.shared.write("ACCESSIBILITY: Pasted \(text.count) chars + Return to \(targetName) (clipboard verification: \(clipboardContent?.count ?? -1) chars)")
        }
    }

    /// Copies text to clipboard and simulates Cmd+V in the frontmost app.
    func pasteText(_ text: String) {
        guard isGranted else {
            DiagLog.shared.write("ACCESSIBILITY: ❌ pasteText skipped — no accessibility permission")
            requestPermission()
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        DiagLog.shared.write("ACCESSIBILITY: pasteText — textLen=\(text.count), frontApp=\(frontApp?.localizedName ?? "nil")")

        // Append trailing space so consecutive transcriptions don't run together
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text + " ", forType: .string)

        Task {
            try? await Task.sleep(for: .milliseconds(50))

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

            let clipboardContent = NSPasteboard.general.string(forType: .string)
            DiagLog.shared.write("ACCESSIBILITY: Pasted \(text.count) chars via Cmd+V (clipboard verification: \(clipboardContent?.count ?? -1) chars)")
        }
    }
}

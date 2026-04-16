import AppKit
import os.log

private let panelLogger = Logger(subsystem: "com.ruban.rhythm", category: "PanelManager")

@MainActor
@Observable
final class NotchPanelManager {
    static let shared = NotchPanelManager()

    private(set) var isExpanded = false
    private(set) var isPinned = false
    private(set) var notchSize: CGSize = .zero
    private(set) var notchRect: CGRect = .zero
    private(set) var panelRect: CGRect = .zero
    private(set) var systemNotchPath: CGPath?
    private var screenHeight: CGFloat = 0

    private var mouseDownMonitor: EventMonitor?
    private var hoverTimer: Timer?
    private var collapseTimer: Timer?

    private init() {
        setupEventMonitors()
    }

    func updateGeometry(for screen: NSScreen) {
        let newNotchSize = screen.notchSize
        let screenFrame = screen.frame

        notchSize = newNotchSize
        systemNotchPath = screen.notchPath

        let notchCenterX = screenFrame.origin.x + screenFrame.width / 2
        let sideWidth = max(0, newNotchSize.height - 12) + 24
        // Match original Rhythm: one side width
        let notchTotalWidth = newNotchSize.width + sideWidth

        notchRect = CGRect(
            x: notchCenterX - notchTotalWidth / 2,
            y: screenFrame.maxY - newNotchSize.height,
            width: notchTotalWidth,
            height: newNotchSize.height
        )

        let panelSize = NotchConstants.expandedPanelSize
        let panelWidth = panelSize.width + NotchConstants.expandedPanelHorizontalPadding
        panelRect = CGRect(
            x: notchCenterX - panelWidth / 2,
            y: screenFrame.maxY - panelSize.height,
            width: panelWidth,
            height: panelSize.height
        )

        screenHeight = screenFrame.height
    }

    private func setupEventMonitors() {
        // Click detection — works without Accessibility permission
        mouseDownMonitor = EventMonitor(mask: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in self?.handleMouseDown() }
        }
        mouseDownMonitor?.start()

        // Hover via NSTrackingArea is set up on the NotchHitTestView instead
        // (doesn't require Accessibility permission)
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation

        if isExpanded {
            if !isPinned && !panelRect.contains(location) {
                collapse()
            }
        } else {
            if notchRect.contains(location) {
                expand()
            }
        }
    }

    func expand() {
        guard !isExpanded else { return }
        isExpanded = true
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        isPinned = false
    }

    func toggle() {
        isExpanded ? collapse() : expand()
    }

    func togglePin() {
        isPinned.toggle()
    }

    func handleVoiceStateChange(_ state: VoiceState) {
        switch state {
        case .agentThinking, .agentResponse:
            // Auto-expand when the agent is responding so the user sees the reply.
            expand()
        default:
            // All other states (recording, processing, success, idle) leave the
            // panel to normal hover-driven expand/collapse — no auto-expand on Fn.
            break
        }
    }
}

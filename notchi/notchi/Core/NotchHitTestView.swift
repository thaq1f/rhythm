import AppKit

/// Hover detection via mouse-position polling.
/// Replaces NSTrackingArea which is fragile with non-activating panels —
/// system UI (emoji picker, dictation) can permanently break event routing.
/// Polling NSEvent.mouseLocation is immune to all external interference.
final class NotchHitTestView: NSView {
    weak var panelManager: NotchPanelManager?

    private var hoverPollTimer: Timer?
    private var mouseOutsideSince: Date?
    private let collapseDelay: TimeInterval = 0.6
    private var pollCount = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startHoverPolling()
    }

    override func removeFromSuperview() {
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
        super.removeFromSuperview()
    }

    private func startHoverPolling() {
        hoverPollTimer?.invalidate()
        // 30fps — reads NSEvent.mouseLocation and compares against rects
        hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMouse() }
        }
    }

    private var lastLoggedExpanded: Bool?
    private var timerHealthCount = 0

    private func pollMouse() {
        guard let manager = panelManager, let window else {
            timerHealthCount += 1
            if timerHealthCount % 300 == 0 { // every 10s
                DiagLog.shared.write("HOVER: ⚠️ pollMouse guard failed — manager=\(panelManager != nil), window=\(self.window != nil)")
            }
            return
        }

        // Keep panel at front every ~5 seconds (150 ticks at 30fps)
        pollCount += 1
        if pollCount % 150 == 0 {
            window.orderFrontRegardless()
        }

        // Log timer health every 30s
        timerHealthCount += 1
        if timerHealthCount % 900 == 0 {
            DiagLog.shared.write("HOVER: Timer alive (tick \(timerHealthCount)), expanded=\(manager.isExpanded), pinned=\(manager.isPinned)")
        }

        let mouse = NSEvent.mouseLocation
        let inNotch = manager.notchRect.contains(mouse)
        let inPanel = manager.panelRect.contains(mouse)

        if manager.isExpanded {
            if inPanel {
                mouseOutsideSince = nil
            } else if !manager.isPinned {
                if mouseOutsideSince == nil {
                    mouseOutsideSince = Date()
                } else if Date().timeIntervalSince(mouseOutsideSince!) >= collapseDelay {
                    DiagLog.shared.write("HOVER: Collapsing (mouse outside for \(collapseDelay)s)")
                    manager.collapse()
                    mouseOutsideSince = nil
                }
            }
        } else {
            mouseOutsideSince = nil
            if inNotch {
                DiagLog.shared.write("HOVER: Expanding (mouse in notch)")
                manager.expand()
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window, let manager = panelManager else { return nil }
        let screenPoint = window.convertPoint(toScreen: convert(point, to: nil))
        let activeRect = manager.isExpanded ? manager.panelRect : manager.notchRect
        guard activeRect.contains(screenPoint) else { return nil }
        return super.hitTest(point)
    }
}

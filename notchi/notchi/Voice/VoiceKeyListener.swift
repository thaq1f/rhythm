import AppKit
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "VoiceKeys")

/// Push-to-talk via multiple event sources.
/// Primary: CGEvent tap for Fn/Globe key (requires Accessibility permission).
/// Fallback: NSEvent flagsChanged monitors for Right Option key (no permission needed).
@MainActor
final class VoiceKeyListener {
    static let shared = VoiceKeyListener()

    var onRecordStart: (() -> Void)?
    var onRecordStop: (() -> Void)?

    private(set) var activeHotkey = "Hold Fn or Right ⌥"
    private(set) var hasAccessibility = false

    private enum HoldSource { case none, fn, rightOption }
    private var holdSource: HoldSource = .none
    private var isHolding: Bool { holdSource != .none }

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var tapConsumesEvents = false

    private var holdTimeoutTask: Task<Void, Never>?
    private let maxHoldDuration: TimeInterval = 30

    private init() {}

    func start() {
        startNSEventMonitors()
        startCGEventTap()
    }

    func stop() {
        stopNSEventMonitors()
        stopCGEventTap()
        cancelHoldTimeout()
    }

    // MARK: - NSEvent monitors (Right Option key)

    private func startNSEventMonitors() {
        guard globalFlagsMonitor == nil else { return }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handleNSFlags(event) }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handleNSFlags(event) }
            return event
        }
        logger.info("NSEvent flag monitors started")
    }

    private func stopNSEventMonitors() {
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m); globalFlagsMonitor = nil }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m); localFlagsMonitor = nil }
    }

    private func handleNSFlags(_ event: NSEvent) {
        let flags = event.modifierFlags
        let rightOptionDown = flags.contains(.option)
            && (flags.rawValue & UInt(NX_DEVICERALTKEYMASK)) != 0

        if rightOptionDown && !isHolding {
            beginHold(source: .rightOption)
        } else if !rightOptionDown && holdSource == .rightOption {
            endHold()
        }
    }

    // MARK: - CGEvent tap (Fn/Globe key)

    private func startCGEventTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        // Try .defaultTap first — consumes Fn events to prevent emoji picker / dictation.
        // Falls back to .listenOnly if permission not granted (hover polling is immune either way).
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<VoiceKeyListener>.fromOpaque(refcon).takeUnretainedValue()
                return listener.handleCGFlags(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) {
            tapConsumesEvents = true
            installTap(tap)
            logger.info("CGEvent tap started (.defaultTap) — Fn key active, emoji picker suppressed")
            Task { @MainActor in DiagLog.shared.write("KEY: CGEvent tap created with .defaultTap — Fn will be CONSUMED") }
            return
        }

        // Fallback: listen-only (emoji picker may appear but hover polling is immune)
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<VoiceKeyListener>.fromOpaque(refcon).takeUnretainedValue()
                return listener.handleCGFlags(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) {
            tapConsumesEvents = false
            installTap(tap)
            logger.info("CGEvent tap started (.listenOnly) — Fn key active")
            Task { @MainActor in DiagLog.shared.write("KEY: ⚠️ CGEvent tap created with .listenOnly — Fn will PASS THROUGH (emoji picker risk)") }
            return
        }

        logger.warning("CGEvent tap not available (needs Input Monitoring permission) — Fn key disabled")
        hasAccessibility = false
        Task { @MainActor in DiagLog.shared.write("KEY: ❌ CGEvent tap FAILED — no accessibility permission, Fn key disabled") }
    }

    private func installTap(_ tap: CFMachPort) {
        hasAccessibility = true
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopCGEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
    }

    /// Returns nil for Fn key events when consuming, passes all other modifiers through.
    private nonisolated func handleCGFlags(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor [weak self] in
                guard let self, let tap = self.eventTap else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
                logger.info("Re-enabled CGEvent tap after system disabled it")
                DiagLog.shared.write("KEY: ⚠️ Tap was disabled by system (type=\(type.rawValue)), re-enabled")
                let flags = CGEventSource.flagsState(.hidSystemState)
                if self.holdSource == .fn && !flags.contains(.maskSecondaryFn) {
                    self.endHold()
                    logger.warning("Fn released while tap was disabled — ended hold")
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == 63 else {
            return Unmanaged.passUnretained(event)
        }

        let fnDown = event.flags.contains(.maskSecondaryFn)

        Task { @MainActor [weak self] in
            guard let self else { return }
            if fnDown && !self.isHolding {
                DiagLog.shared.write("KEY: Fn DOWN — starting hold (consuming=\(self.tapConsumesEvents))")
                self.beginHold(source: .fn)
            } else if !fnDown && self.holdSource == .fn {
                DiagLog.shared.write("KEY: Fn UP — ending hold")
                self.endHold()
            }
        }

        // Consume Fn events only when using .defaultTap
        return tapConsumesEvents ? nil : Unmanaged.passUnretained(event)
    }

    // MARK: - Shared hold state

    private func beginHold(source: HoldSource) {
        guard !isHolding else { return }
        holdSource = source
        startHoldTimeout()
        logger.debug("Hold started (source: \(source == .fn ? "Fn" : "Right ⌥", privacy: .public))")
        onRecordStart?()
    }

    private func endHold() {
        guard isHolding else { return }
        let src = holdSource
        holdSource = .none
        cancelHoldTimeout()
        logger.debug("Hold ended (source: \(src == .fn ? "Fn" : "Right ⌥", privacy: .public))")
        onRecordStop?()
    }

    func resetIfStuck() {
        guard isHolding else { return }
        logger.warning("Force-resetting stuck key hold state")
        endHold()
    }

    func recheckAccessibility() {
        if !tapConsumesEvents {
            // We have a .listenOnly tap (or none). Stop it and try .defaultTap again.
            stopCGEventTap()
            startCGEventTap()
        } else if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func startHoldTimeout() {
        holdTimeoutTask?.cancel()
        holdTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.maxHoldDuration ?? 30))
            guard !Task.isCancelled else { return }
            self?.resetIfStuck()
        }
    }

    private func cancelHoldTimeout() {
        holdTimeoutTask?.cancel()
        holdTimeoutTask = nil
    }
}

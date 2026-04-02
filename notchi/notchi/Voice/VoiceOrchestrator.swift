import AVFoundation
import Foundation
import Observation
import Combine
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "VoiceOrchestrator")

@MainActor
@Observable
final class VoiceOrchestrator {
    static let shared = VoiceOrchestrator()

    let presentationState = VoicePresentationState()

    private let capture = VoiceCaptureService.shared
    private let keyListener = VoiceKeyListener.shared
    private var durationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isRecording = false
    private var permissionGranted: Bool?  // nil = unchecked

    private init() {
        wireKeyListener()
        observeAudioLevel()
    }

    func start() {
        keyListener.start()

        // Synchronously resolve permission for .authorized / .denied so the
        // first key-press is never eaten by a nil check.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            permissionGranted = true
            capture.checkPermission()
        case .denied, .restricted:
            permissionGranted = false
        case .notDetermined:
            // Only go async when the system hasn't been asked yet.
            Task { permissionGranted = await capture.requestPermission() }
        @unknown default:
            permissionGranted = false
        }

        // Start loading Parakeet model in background so it's ready for first Fn press
        Task { await TranscriptionService.shared.warmUp() }

        logger.info("Voice orchestrator started (mic: \(String(describing: self.permissionGranted)))")
    }

    /// Re-check accessibility + mic after the user returns from System Settings.
    func recheckPermissions() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        permissionGranted = (status == .authorized)
        capture.checkPermission()
        keyListener.recheckAccessibility()
        logger.info("Permissions rechecked — mic: \(self.permissionGranted ?? false), accessibility: \(self.keyListener.hasAccessibility)")
    }

    func stop() {
        keyListener.stop()
        stopDurationTimer()
    }

    private func wireKeyListener() {
        keyListener.onRecordStart = { [weak self] in self?.handleRecordStart() }
        keyListener.onRecordStop = { [weak self] in self?.handleRecordStop() }
    }

    func toggleRecording() {
        if isRecording { handleRecordStop() } else { handleRecordStart() }
    }

    // MARK: - Record Start (NEVER blocks main thread)

    private func handleRecordStart() {
        DiagLog.shared.write("VOICE: handleRecordStart called (isRecording=\(isRecording), captureRecording=\(capture.isRecording), permission=\(permissionGranted ?? false))")
        // Safety: if a previous recording got stuck, force-reset before starting
        if isRecording && !capture.isRecording {
            logger.warning("Resetting stuck recording state")
            isRecording = false
            stopDurationTimer()
            presentationState.reset()
        }

        guard !isRecording else { return }

        // If somehow still nil (e.g. start() Task hasn't resolved yet), do a
        // synchronous check so we don't eat the key press.
        if permissionGranted == nil {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .authorized {
                permissionGranted = true
                capture.checkPermission()
            } else if status == .notDetermined {
                Task { permissionGranted = await capture.requestPermission() }
                presentationState.currentState = .processing(hint: "Requesting mic access…")
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if presentationState.currentState.isProcessing { presentationState.reset() }
                }
                return
            } else {
                permissionGranted = false
            }
        }

        guard permissionGranted == true else {
            // Show hint in compact view
            presentationState.currentState = .processing(hint: "Grant mic in Settings")
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                presentationState.reset()
            }
            return
        }

        // Permission is granted — start immediately, no async
        DiagLog.shared.write("VOICE: Starting capture")
        capture.startRecording()
        DiagLog.shared.write("VOICE: startRecording() returned, isRecording=\(capture.isRecording)")

        // Verify capture actually started (it can fail silently if device unavailable)
        guard capture.isRecording else {
            DiagLog.shared.write("VOICE: ❌ Capture failed to start")
            logger.error("Capture failed to start")
            presentationState.currentState = .processing(hint: "Mic unavailable")
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                presentationState.reset()
            }
            return
        }

        isRecording = true
        DiagLog.shared.write("VOICE: Setting state to .recording")
        presentationState.currentState = .recording
        presentationState.duration = 0
        startDurationTimer()
        DiagLog.shared.write("VOICE: Recording fully started, duration timer running")
    }

    // MARK: - Record Stop

    private func handleRecordStop() {
        DiagLog.shared.write("VOICE: handleRecordStop called (isRecording=\(isRecording))")
        stopDurationTimer()
        guard isRecording else {
            // Key released but we weren't recording — ensure clean state
            if presentationState.currentState != .idle {
                presentationState.reset()
            }
            return
        }
        isRecording = false

        presentationState.currentState = .processing(hint: "transcribing…")

        let audioURL = capture.stopRecording()
        processRecording(audioURL: audioURL)
    }

    private func processRecording(audioURL: URL?) {
        Task {
            guard let audioURL else {
                DiagLog.shared.write("VOICE: No audio URL, resetting")
                presentationState.reset()
                return
            }

            do {
                // Update hint live: "loading model…" while Parakeet warms up, then "transcribing…"
                let hintTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    while !Task.isCancelled {
                        let isLoading = await TranscriptionService.shared.isModelLoading
                        self.presentationState.currentState = .processing(hint: isLoading ? "loading model…" : "transcribing…")
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                let transcript = try await TranscriptionService.shared.transcribe(audioURL)
                hintTask.cancel()

                // Clean up temp audio file
                try? FileManager.default.removeItem(at: audioURL)

                guard !transcript.isEmpty else {
                    DiagLog.shared.write("VOICE: Empty transcript, resetting")
                    presentationState.reset()
                    return
                }

                // Route: if the notch panel is open, try to inject into the active Claude tty.
                let panelOpen = NotchPanelManager.shared.isExpanded
                let activeSession = SessionStore.shared.effectiveSession

                if panelOpen, let session = activeSession {
                    // Show transcript bubble immediately (optimistic).
                    SessionStore.shared.recordVoicePrompt(transcript, for: session.id)
                    presentationState.currentState = .processing(hint: "sending…")

                    // Resolve tty — three escalating fallbacks:
                    // 1. Stored tty from hook events
                    // 2. ps lookup from stored pid (works if same process is still alive)
                    // 3. System-wide scan for any running claude process
                    let resolvedTTY: String?
                    if let stored = session.tty {
                        resolvedTTY = stored
                        DiagLog.shared.write("VOICE: Using stored tty \(stored)")
                    } else if let pid = session.pid,
                              let found = await Task.detached(priority: .userInitiated) { TTYInputService.lookupTTY(for: pid) }.value {
                        resolvedTTY = found
                        DiagLog.shared.write("VOICE: ps lookup found tty \(found) for pid \(pid)")
                    } else {
                        let cwd = session.cwd
                        resolvedTTY = await Task.detached(priority: .userInitiated) {
                            TTYInputService.findClaudeTTY(preferringCWD: cwd)
                        }.value
                        if let t = resolvedTTY { DiagLog.shared.write("VOICE: System scan found tty \(t)") }
                        else { DiagLog.shared.write("VOICE: No claude tty found system-wide") }
                    }

                    if let tty = resolvedTTY {
                        let ok = await TTYInputService.shared.injectText(transcript, into: tty)
                        if !ok {
                            DiagLog.shared.write("VOICE: TTY injection failed")
                            SessionStore.shared.clearVoicePrompt(for: session.id)
                            presentationState.currentState = .processing(hint: "couldn't reach Claude")
                            try? await Task.sleep(for: .seconds(1.5))
                            presentationState.reset()
                            return
                        }
                    } else {
                        // No interactive terminal found — fall back to paste+Return.
                        // Conductor (and other GUI apps) remain the frontmost app since the
                        // notch panel is non-activating, so paste goes directly to their input.
                        DiagLog.shared.write("VOICE: No interactive tty — pasting to frontmost app")
                        SessionStore.shared.clearVoicePrompt(for: session.id)
                        AccessibilityService.shared.pasteTextAndReturn(transcript)
                    }
                } else {
                    DiagLog.shared.write("VOICE: Pasting \(transcript.count) chars via Cmd+V")
                    AccessibilityService.shared.pasteText(transcript)
                }

                presentationState.currentState = .success
                try? await Task.sleep(for: .seconds(0.6))
                presentationState.reset()
            } catch {
                logger.error("Transcription failed: \(error)")
                DiagLog.shared.write("VOICE: Transcription error: \(error.localizedDescription)")
                presentationState.currentState = .processing(hint: "Transcription failed")
                try? await Task.sleep(for: .seconds(1.5))
                presentationState.reset()
            }
        }
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        durationTimer?.invalidate()
        let start = Date()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.presentationState.duration = Date().timeIntervalSince(start) }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate(); durationTimer = nil
    }

    // MARK: - Audio Level

    private func observeAudioLevel() {
        capture.$audioLevel
            .throttle(for: .milliseconds(8), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] level in
                guard let self, self.presentationState.currentState.isRecording else { return }
                self.presentationState.audioLevel = level
            }
            .store(in: &cancellables)
    }

    func dismissResponse() { presentationState.reset() }
}

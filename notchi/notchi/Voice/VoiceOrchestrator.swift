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
    private var processingTask: Task<Void, Never>?

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
        // Cancel any previous transcription/injection so we don't accumulate stuck tasks.
        processingTask?.cancel()
        processingTask = nil
        if presentationState.currentState != .idle && !isRecording {
            presentationState.reset()
        }
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
        processingTask?.cancel()
        // Capture routing state NOW (synchronously, before any async gap).
        // panelOpen / activeSession must not be read after await — by then the
        // user may have moved their mouse away and the panel may have collapsed.
        let panelWasOpen = NotchPanelManager.shared.isExpanded
        let capturedSession = SessionStore.shared.effectiveSession
        processingTask = Task {
            guard let audioURL else {
                DiagLog.shared.write("VOICE: No audio URL, resetting")
                presentationState.reset()
                return
            }

            // Update hint live — declared outside do/catch so it can be cancelled in either path.
            var hintTask: Task<Void, Never>? = Task { @MainActor [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    let isLoading = await TranscriptionService.shared.isModelLoading
                    self.presentationState.currentState = .processing(hint: isLoading ? "loading model…" : "transcribing…")
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            do {
                let transcript = try await TranscriptionService.shared.transcribe(audioURL)
                hintTask?.cancel()
                hintTask = nil

                // Clean up temp audio file
                try? FileManager.default.removeItem(at: audioURL)

                guard !transcript.isEmpty else {
                    DiagLog.shared.write("VOICE: Empty transcript, resetting")
                    presentationState.reset()
                    return
                }

                // Route using state captured at Fn-UP time (before the async transcription gap).
                DiagLog.shared.write("VOICE: routing — panelWasOpen=\(panelWasOpen), hasSession=\(capturedSession != nil)")
                if panelWasOpen, let session = capturedSession {
                    // Warn if Claude is currently processing — the message will queue.
                    let isClaudeBusy = session.task == .working || session.task == .compacting
                    // Show transcript bubble immediately (optimistic).
                    SessionStore.shared.recordVoicePrompt(transcript, for: session.id)
                    presentationState.currentState = .processing(hint: isClaudeBusy ? "queuing…" : "sending…")

                    // Resolve tty from this session's own identity only.
                    // System-wide process scan is intentionally absent — it would find
                    // an unrelated terminal Claude and inject there instead of the
                    // correct target (e.g. it would miss Conductor and hit a Terminal).
                    let resolvedTTY: String?
                    if let stored = session.tty {
                        resolvedTTY = stored
                        DiagLog.shared.write("VOICE: Using stored tty \(stored)")
                    } else if let pid = session.pid, pid > 0,
                              let found = await Task.detached(priority: .userInitiated) { TTYInputService.lookupTTY(for: pid) }.value {
                        resolvedTTY = found
                        DiagLog.shared.write("VOICE: ps lookup found tty \(found) for pid \(pid)")
                    } else {
                        resolvedTTY = nil
                        DiagLog.shared.write("VOICE: No tty for session — falling back to paste")
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
                        // No session tty — paste to the last focused app.
                        // The notch is non-activating, so Conductor / Terminal / whichever
                        // the user was in before hovering is still the key-event target.
                        DiagLog.shared.write("VOICE: No session tty — pasting+Return to frontmost app")
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
                hintTask?.cancel()     // stop the loading/transcribing loop immediately
                hintTask = nil
                logger.error("Transcription failed: \(error)")
                DiagLog.shared.write("VOICE: Transcription error: \(error.localizedDescription)")
                presentationState.currentState = .processing(hint: "transcription failed")
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

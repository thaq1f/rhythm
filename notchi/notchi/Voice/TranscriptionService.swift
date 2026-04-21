import Foundation
import FluidAudio
import os.log

private let logger = Logger(subsystem: "com.silca.rhythm", category: "Transcription")

/// Local speech-to-text using FluidAudio's Parakeet TDT 0.6B v3 on Apple Neural Engine.
/// Initialized eagerly at app launch so the model is ready before the first Fn press.
actor TranscriptionService {
    static let shared = TranscriptionService()

    private var asrManager: AsrManager?
    private var isInitializing = false

    enum State { case idle, loading, ready, failed(String) }
    private(set) var state: State = .idle

    /// True while the model is downloading or initializing.
    var isModelLoading: Bool { if case .loading = state { return true }; return false }

    /// True when the model is loaded and ready to transcribe.
    var isReady: Bool { if case .ready = state { return true }; return false }

    /// Download model (~600MB first time) and load onto ANE. Safe to call multiple times.
    func warmUp() async {
        guard case .idle = state else { return }
        guard !isInitializing else { return }
        isInitializing = true
        defer { isInitializing = false }

        state = .loading
        let warmupStart = ContinuousClock.now
        logger.info("Warming up Parakeet TDT v3…")

        do {
            let mgr = AsrManager()
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            try await mgr.initialize(models: models)
            asrManager = mgr          // only set after successful init
            state = .ready
            let warmupMs = (ContinuousClock.now - warmupStart).ms
            logger.info("⏱ model warmup: \(warmupMs)ms")
        } catch {
            let msg = error.localizedDescription
            state = .failed(msg)
            logger.error("Parakeet init failed: \(msg)")
        }
    }

    /// Transcribe a 16kHz mono WAV file. Auto-initializes if not yet ready.
    func transcribe(_ audioURL: URL) async throws -> String {
        // Start warmup if not yet begun
        if case .idle = state {
            logger.info("Model idle — triggering warmup before transcription")
            await warmUp()
        }

        // If still loading (warmup started elsewhere), poll until done
        if case .loading = state {
            logger.info("Model still loading — polling (up to 30s)")
            var waited = 0
            while case .loading = state, waited < 60 {
                try await Task.sleep(for: .milliseconds(500))
                waited += 1
            }
            logger.info("Model loading poll finished after \(waited * 500)ms — state now: \(String(describing: self.state))")
        }

        guard let mgr = asrManager, case .ready = state else {
            logger.error("Model not ready after waiting — state: \(String(describing: self.state))")
            throw TranscriptionError.notReady
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? -1
        logger.info("Transcribing \(audioURL.lastPathComponent) (\(fileSize) bytes)")
        let result = try await mgr.transcribe(audioURL, source: .microphone)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Transcribed \(text.count) chars: \"\(String(text.prefix(60)))\"")
        return text
    }

    enum TranscriptionError: LocalizedError {
        case notReady
        var errorDescription: String? {
            switch self { case .notReady: return "Transcription model not loaded" }
        }
    }
}

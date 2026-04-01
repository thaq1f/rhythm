import Foundation
import FluidAudio
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "Transcription")

/// Local speech-to-text using FluidAudio's Parakeet TDT 0.6B v3 on Apple Neural Engine.
/// Initialized eagerly at app launch so the model is ready before the first Fn press.
actor TranscriptionService {
    static let shared = TranscriptionService()

    private var asrManager: AsrManager?
    private var isInitializing = false

    enum State { case idle, loading, ready, failed(String) }
    private(set) var state: State = .idle

    /// Download model (~600MB first time) and load onto ANE. Safe to call multiple times.
    func warmUp() async {
        guard case .idle = state else { return }
        guard !isInitializing else { return }
        isInitializing = true
        defer { isInitializing = false }

        state = .loading
        logger.info("Warming up Parakeet TDT v3…")

        do {
            asrManager = AsrManager()
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            try await asrManager?.initialize(models: models)
            state = .ready
            logger.info("Parakeet ready")
        } catch {
            let msg = error.localizedDescription
            state = .failed(msg)
            logger.error("Parakeet init failed: \(msg)")
        }
    }

    /// Transcribe a 16kHz mono WAV file. Auto-initializes if not yet ready.
    func transcribe(_ audioURL: URL) async throws -> String {
        if asrManager == nil { await warmUp() }
        guard let mgr = asrManager else {
            throw TranscriptionError.notReady
        }

        logger.info("Transcribing \(audioURL.lastPathComponent)")
        let result = try await mgr.transcribe(audioURL)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Transcribed \(text.count) chars")
        return text
    }

    enum TranscriptionError: LocalizedError {
        case notReady
        var errorDescription: String? {
            switch self { case .notReady: return "Transcription model not loaded" }
        }
    }
}

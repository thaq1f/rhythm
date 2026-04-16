import Foundation
import Observation
import os.log

private let logger = Logger(subsystem: "com.ruban.rhythm", category: "AgentSessions")

struct ConversationMessage: Identifiable {
    let id = UUID()
    let role: Role
    let content: String
    let timestamp: Date

    enum Role {
        case user
        case agent
        case system
        case toolUse(name: String)
        case toolResult(name: String)
        case thinking
    }
}

@MainActor
@Observable
final class AgentSessionManager {
    static let shared = AgentSessionManager()

    private(set) var activeProvider: (any AgentProvider)?
    private(set) var messages: [ConversationMessage] = []
    private(set) var streamingText: String = ""
    private(set) var isProcessing = false
    private(set) var activeToolName: String?
    private(set) var error: String?
    private(set) var workingDirectory: URL?

    private var responseTask: Task<Void, Never>?

    private init() {}

    // MARK: - Session Lifecycle

    func startSession(in directory: URL) async {
        terminateSession()

        let provider = ClaudeCodeProvider()
        self.activeProvider = provider
        self.workingDirectory = directory
        self.messages = []
        self.error = nil
        self.activeToolName = nil

        let responses = provider.responses

        do {
            try await provider.spawn(in: directory)
            messages.append(ConversationMessage(
                role: .system,
                content: "Session started in \(directory.lastPathComponent)",
                timestamp: Date()
            ))
            startListening(to: responses)
            logger.info("Session started: \(directory.path)")
        } catch {
            self.error = error.localizedDescription
            logger.error("Start failed: \(error.localizedDescription)")
        }
    }

    func sendPrompt(_ prompt: String) async {
        guard let provider = activeProvider, provider.isRunning else {
            error = "No active session. Start one from Settings."
            return
        }

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(ConversationMessage(
            role: .user, content: trimmed, timestamp: Date()
        ))

        isProcessing = true
        streamingText = ""
        activeToolName = nil
        error = nil

        do {
            try await provider.send(prompt: trimmed)
        } catch {
            isProcessing = false
            self.error = error.localizedDescription
        }
    }

    func sendVoicePrompt(_ transcript: String) async {
        await sendPrompt(transcript)
    }

    func terminateSession() {
        responseTask?.cancel()
        responseTask = nil
        activeProvider?.terminate()
        activeProvider = nil
        isProcessing = false
        streamingText = ""
        activeToolName = nil
    }

    // MARK: - Response Streaming

    private func startListening(to responses: AsyncStream<AgentResponse>) {
        responseTask = Task { [weak self] in
            for await response in responses {
                guard !Task.isCancelled else { break }
                await MainActor.run { self?.handleResponse(response) }
            }
        }
    }

    private func handleResponse(_ response: AgentResponse) {
        switch response.kind {
        case .text(let text):
            guard !text.isEmpty else { return }
            // If we were in a tool, the text is agent response after tool
            if activeToolName != nil {
                activeToolName = nil
            }
            streamingText += text

        case .toolUse(let name, let input):
            // Flush accumulated text as an agent message
            flushStreamingText()
            activeToolName = name
            let display = input.isEmpty ? name : name
            messages.append(ConversationMessage(
                role: .toolUse(name: name),
                content: display,
                timestamp: response.timestamp
            ))

        case .toolResult(let name, let output):
            let truncated = String(output.prefix(500))
            let displayName = name.isEmpty ? (activeToolName ?? "tool") : name
            messages.append(ConversationMessage(
                role: .toolResult(name: displayName),
                content: truncated.isEmpty ? "Done" : truncated,
                timestamp: response.timestamp
            ))
            activeToolName = nil

        case .thinking(let thought):
            if !thought.isEmpty {
                flushStreamingText()
                messages.append(ConversationMessage(
                    role: .thinking,
                    content: thought,
                    timestamp: response.timestamp
                ))
            }

        case .error(let msg):
            flushStreamingText()
            error = msg
            isProcessing = false
            activeToolName = nil

        case .completed:
            flushStreamingText()
            isProcessing = false
            activeToolName = nil
        }
    }

    private func flushStreamingText() {
        let text = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            messages.append(ConversationMessage(
                role: .agent, content: text, timestamp: Date()
            ))
        }
        streamingText = ""
    }
}

import Foundation

/// A streamed response chunk from an AI agent
struct AgentResponse: Sendable {
    enum Kind: Sendable {
        case text(String)
        case toolUse(name: String, input: String)
        case toolResult(name: String, output: String)
        case thinking(String)
        case error(String)
        case completed
    }
    let kind: Kind
    let timestamp: Date
}

/// Protocol for AI coding agent backends.
/// Implementations spawn a child process and communicate via stdin/stdout.
/// Designed so we can add Codex, LM Studio, etc. later.
protocol AgentProvider: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }

    /// Spawn the agent process in the given working directory
    func spawn(in directory: URL) async throws

    /// Send a text prompt to the running agent
    func send(prompt: String) async throws

    /// Stream of responses from the agent
    var responses: AsyncStream<AgentResponse> { get }

    /// Whether the agent process is currently running
    var isRunning: Bool { get }

    /// Kill the agent process
    func terminate()
}

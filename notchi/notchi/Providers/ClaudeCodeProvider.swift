import Foundation
import os.log

private let logger = Logger(subsystem: "com.silca.rhythm", category: "ClaudeCode")

/// Spawns `claude -p` with `--output-format stream-json --include-partial-messages`
/// for each prompt. Maintains conversation via `--session-id` + `-c`.
final class ClaudeCodeProvider: AgentProvider, @unchecked Sendable {
    let id = "claude-code"
    let displayName = "Claude Code"

    private(set) var isRunning = false
    private var sessionUUID: String = UUID().uuidString
    private var workingDir: URL?
    private var claudePath: String?
    private var currentProcess: Process?
    private var isFirstPrompt = true
    private var responseContinuation: AsyncStream<AgentResponse>.Continuation?

    lazy var responses: AsyncStream<AgentResponse> = {
        AsyncStream { [weak self] continuation in
            self?.responseContinuation = continuation
        }
    }()

    func spawn(in directory: URL) async throws {
        guard let path = findClaudeBinary() else {
            throw ProviderError.binaryNotFound("claude")
        }
        self.claudePath = path
        self.workingDir = directory
        self.sessionUUID = UUID().uuidString
        self.isFirstPrompt = true
        self.isRunning = true
        logger.info("Provider ready: \(directory.lastPathComponent), session \(self.sessionUUID)")
    }

    func send(prompt: String) async throws {
        guard isRunning, let claudePath, let workingDir else {
            throw ProviderError.notRunning
        }

        currentProcess?.terminate()
        currentProcess = nil

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)

        var args = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--session-id", sessionUUID,
        ]
        if !isFirstPrompt { args.append("-c") }
        isFirstPrompt = false

        proc.arguments = args
        proc.currentDirectoryURL = workingDir

        var env = ProcessInfo.processInfo.environment
        let homeDir = NSHomeDirectory()
        let extra = ["\(homeDir)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        if let existing = env["PATH"] { env["PATH"] = extra.joined(separator: ":") + ":" + existing }
        env["TERM"] = "xterm-256color"
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Buffer for partial lines
        var lineBuffer = Data()

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lineBuffer.append(data)

            // Split on newlines and process complete lines
            while let newlineRange = lineBuffer.range(of: Data("\n".utf8)) {
                let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<newlineRange.lowerBound)
                lineBuffer.removeSubrange(lineBuffer.startIndex...newlineRange.lowerBound)
                self?.parseLine(lineData)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                logger.warning("stderr: \(text)")
            }
        }

        proc.terminationHandler = { [weak self] p in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            // Process any remaining buffer
            if !lineBuffer.isEmpty { self?.parseLine(lineBuffer) }
            self?.responseContinuation?.yield(AgentResponse(kind: .completed, timestamp: Date()))
            if p.terminationStatus != 0 {
                logger.warning("claude exit status \(p.terminationStatus)")
            }
        }

        self.currentProcess = proc
        try proc.run()
        logger.info("Prompt sent (\(prompt.count) chars)")
    }

    func terminate() {
        currentProcess?.terminate()
        currentProcess = nil
        isRunning = false
        responseContinuation?.finish()
    }

    // MARK: - JSON Line Parsing

    /// Claude Code stream-json emits one JSON object per line.
    /// Key types: "assistant", "content_block_start", "content_block_delta",
    /// "content_block_stop", "message_start", "message_delta", "message_stop", "result"
    private func parseLine(_ data: Data) {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let type = json["type"] as? String ?? ""
        let now = Date()

        switch type {

        // --- Full assistant message (non-streaming fallback) ---
        case "assistant":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if let parsed = parseContentBlock(block) {
                        responseContinuation?.yield(parsed)
                    }
                }
            }

        // --- Streaming content blocks ---
        case "content_block_start":
            if let block = json["content_block"] as? [String: Any] {
                let blockType = block["type"] as? String ?? ""
                if blockType == "tool_use" {
                    let name = block["name"] as? String ?? "tool"
                    let id = block["id"] as? String ?? ""
                    responseContinuation?.yield(AgentResponse(
                        kind: .toolUse(name: name, input: id),
                        timestamp: now
                    ))
                }
                // text blocks start empty — content comes via deltas
            }

        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any] {
                let deltaType = delta["type"] as? String ?? ""
                if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                    responseContinuation?.yield(AgentResponse(kind: .text(text), timestamp: now))
                } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String, !partial.isEmpty {
                    // Tool input streaming — show as tool activity
                    responseContinuation?.yield(AgentResponse(kind: .text(partial), timestamp: now))
                }
            }

        case "content_block_stop":
            // Block finished — flush marker
            responseContinuation?.yield(AgentResponse(kind: .text(""), timestamp: now))

        // --- Message-level events ---
        case "message_start":
            // New message starting — could inspect role here
            break

        case "message_delta":
            if let delta = json["delta"] as? [String: Any],
               let stopReason = delta["stop_reason"] as? String {
                if stopReason == "tool_use" {
                    // Model wants to use a tool — result will come as tool_result
                    responseContinuation?.yield(AgentResponse(kind: .thinking("Using tools..."), timestamp: now))
                }
            }

        case "message_stop":
            break

        // --- Tool results ---
        case "tool_result":
            let name = json["name"] as? String ?? json["tool_use_id"] as? String ?? "tool"
            let content = json["content"] as? String
                ?? (json["content"] as? [[String: Any]])?.compactMap({ $0["text"] as? String }).joined(separator: "\n")
                ?? ""
            responseContinuation?.yield(AgentResponse(
                kind: .toolResult(name: name, output: String(content.prefix(800))),
                timestamp: now
            ))

        // --- Final result ---
        case "result":
            if let result = json["result"] as? String, !result.isEmpty {
                responseContinuation?.yield(AgentResponse(kind: .text(result), timestamp: now))
            } else if let message = json["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] {
                // Extract text from result message content blocks
                for block in content {
                    if let parsed = parseContentBlock(block) {
                        responseContinuation?.yield(parsed)
                    }
                }
            }

        case "error":
            let msg = (json["error"] as? [String: Any])?["message"] as? String
                ?? json["error"] as? String
                ?? "Unknown error"
            responseContinuation?.yield(AgentResponse(kind: .error(msg), timestamp: now))

        default:
            break
        }
    }

    /// Parse a content block from an assistant message
    private func parseContentBlock(_ block: [String: Any]) -> AgentResponse? {
        let blockType = block["type"] as? String ?? ""
        let now = Date()

        switch blockType {
        case "text":
            if let text = block["text"] as? String, !text.isEmpty {
                return AgentResponse(kind: .text(text), timestamp: now)
            }
        case "tool_use":
            let name = block["name"] as? String ?? "tool"
            let input = (block["input"] as? [String: Any]).flatMap {
                try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed)
            }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return AgentResponse(kind: .toolUse(name: name, input: String(input.prefix(300))), timestamp: now)
        case "tool_result":
            let content = block["content"] as? String ?? ""
            return AgentResponse(kind: .toolResult(name: "tool", output: String(content.prefix(500))), timestamp: now)
        default:
            break
        }
        return nil
    }

    // MARK: - Find Binary

    private func findClaudeBinary() -> String? {
        let homeDir = NSHomeDirectory()
        let candidates = [
            "\(homeDir)/.local/bin/claude",
            "/usr/local/bin/claude",
            "\(homeDir)/.npm-global/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

enum ProviderError: LocalizedError {
    case binaryNotFound(String)
    case alreadyRunning
    case notRunning
    case spawnFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let name): return "\(name) not found. Install it first."
        case .alreadyRunning: return "Agent is already running."
        case .notRunning: return "Agent is not running."
        case .spawnFailed(let reason): return "Failed to start: \(reason)"
        }
    }
}

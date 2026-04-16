import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.rhythm", category: "SessionStore")

@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [String: SessionData] = [:]
    private(set) var selectedSessionId: String?
    /// The session that most recently received a hook event (likely the active workspace in Conductor).
    private(set) var lastHookSessionId: String?
    private var nextSessionNumberByProject: [String: Int] = [:]

    private init() {}

    var sortedSessions: [SessionData] {
        sessions.values.sorted { lhs, rhs in
            if lhs.isProcessing != rhs.isProcessing {
                return lhs.isProcessing
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    var activeSessionCount: Int {
        sessions.count
    }

    var selectedSession: SessionData? {
        guard let id = selectedSessionId else { return nil }
        return sessions[id]
    }

    var effectiveSession: SessionData? {
        if let selected = selectedSession {
            return selected
        }
        if sessions.count == 1 {
            return sessions.values.first
        }
        return sortedSessions.first
    }

    func selectSession(_ sessionId: String?) {
        if let id = sessionId {
            guard sessions[id] != nil else { return }
        }
        selectedSessionId = sessionId
        logger.info("Selected session: \(sessionId ?? "nil", privacy: .public)")
    }

    func process(_ event: HookEvent, clientSocket: Int32? = nil) -> SessionData {
        let _tty = event.tty ?? "nil"; let _pid = event.pid.map(String.init) ?? "nil"
        DiagLog.shared.write("SESSION: Hook \(event.event) for \(event.sessionId.prefix(8))… tty=\(_tty) pid=\(_pid)")

        // Ignore hooks from non-project paths (e.g. /tmp from manual tests)
        let cwd = event.cwd
        if cwd == "/tmp" || cwd == "/" || cwd.isEmpty {
            DiagLog.shared.write("SESSION: Ignoring hook from non-project cwd: \(cwd)")
            return SessionData(sessionId: event.sessionId, cwd: cwd, sessionNumber: 0, isInteractive: true, existingXPositions: [])
        }

        lastHookSessionId = event.sessionId
        let isInteractive = event.interactive ?? true
        let session = getOrCreateSession(sessionId: event.sessionId, cwd: event.cwd, isInteractive: isInteractive)
        session.updatePid(event.pid)
        session.updateTty(event.tty)
        let isProcessing = event.status != "waiting_for_input"
        session.updateProcessingState(isProcessing: isProcessing)

        if let mode = event.permissionMode {
            session.updatePermissionMode(mode)
        }

        switch event.event {
        case "UserPromptSubmit":
            session.setPendingVoicePrompt(nil)
            if let prompt = event.userPrompt {
                session.recordUserPrompt(prompt)
            }
            session.clearAssistantMessages()
            session.clearPendingQuestions()
            if Self.isLocalSlashCommand(event.userPrompt) {
                session.updateTask(.idle)
            } else {
                session.updateTask(.working)
            }

        case "PreCompact":
            session.updateTask(.compacting)

        case "SessionStart":
            if isProcessing {
                session.updateTask(.working)
            }

        case "PreToolUse":
            let toolInput = event.toolInput?.mapValues { $0.value }
            session.recordPreToolUse(tool: event.tool, toolInput: toolInput, toolUseId: event.toolUseId)
            if Self.isAskUserQuestion(event.tool) {
                session.updateTask(.waiting)
                session.setPendingQuestions(Self.parseQuestions(from: event.toolInput))
                if let fd = clientSocket {
                    session.setPendingResponse(PendingResponse(clientSocket: fd, eventType: event.event))
                    scheduleResponseTimeout(sessionId: event.sessionId)
                }
            } else if Self.needsPermissionApproval(tool: event.tool, permissionMode: session.permissionMode) {
                // Sessions without a TTY are managed by a host (e.g. Conductor)
                // that handles its own permissions — auto-allow, don't double-prompt.
                if session.tty == nil {
                    session.clearPendingQuestions()
                    session.updateTask(.working)
                    if let fd = clientSocket {
                        Self.respondAllow(to: fd)
                    }
                } else {
                    // Terminal session — hold the socket open for user approval
                    let question = Self.buildPermissionQuestion(tool: event.tool, toolInput: event.toolInput)
                    session.updateTask(.waiting)
                    session.setPendingQuestions([question])
                    if let fd = clientSocket {
                        session.setPendingResponse(PendingResponse(clientSocket: fd, eventType: event.event))
                        scheduleResponseTimeout(sessionId: event.sessionId)
                    } else {
                        // No socket — display-only, user responds in terminal
                        session.updateTask(.working)
                    }
                }
            } else {
                // Safe tool or auto-approved — respond immediately and proceed
                session.clearPendingQuestions()
                session.updateTask(.working)
                if let fd = clientSocket {
                    Self.respondAllow(to: fd)
                }
            }

        case "PermissionRequest":
            // Skip display for host-managed sessions (Conductor) — the host owns the UI.
            if session.tty == nil { break }
            // Informational only — PermissionRequest hooks are non-blocking in Claude Code.
            // If we already have a pending response from PreToolUse, don't overwrite it.
            if session.pendingResponse == nil {
                let question = Self.buildPermissionQuestion(tool: event.tool, toolInput: event.toolInput)
                session.updateTask(.waiting)
                session.setPendingQuestions([question])
            }

        case "PostToolUse":
            let success = event.status != "error"
            session.recordPostToolUse(tool: event.tool, toolUseId: event.toolUseId, success: success)
            // Don't clear questions if user hasn't responded yet
            if session.pendingResponse == nil {
                session.clearPendingQuestions()
            }
            session.updateTask(.working)

        case "Stop", "SubagentStop":
            session.clearPendingQuestions()
            if let result = event.result, !result.isEmpty {
                let msg = AssistantMessage(id: event.sessionId + "-stop", text: result, timestamp: Date())
                session.recordAssistantMessages([msg])
            }
            session.updateTask(.idle)

        case "SessionEnd":
            session.updateTask(.sleeping)
            session.updateProcessingState(isProcessing: false)
            scheduleAutoRemoval(sessionId: event.sessionId, delay: 30)

        default:
            if !isProcessing && session.task != .idle {
                session.updateTask(.idle)
            }
        }

        schedulePersist()
        return session
    }

    func recordVoicePrompt(_ text: String, for sessionId: String) {
        sessions[sessionId]?.setPendingVoicePrompt(text)
    }

    func clearVoicePrompt(for sessionId: String) {
        sessions[sessionId]?.setPendingVoicePrompt(nil)
    }

    func recordAssistantMessages(_ messages: [AssistantMessage], for sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        session.recordAssistantMessages(messages)
    }

    private func getOrCreateSession(sessionId: String, cwd: String, isInteractive: Bool) -> SessionData {
        if let existing = sessions[sessionId] {
            // Cancel pending auto-removal — session is active again
            autoRemovalTasks[sessionId]?.cancel()
            autoRemovalTasks.removeValue(forKey: sessionId)
            return existing
        }

        let projectName = (cwd as NSString).lastPathComponent
        let existingForProject = sessions.values.filter { $0.projectName == projectName }.count
        let sessionNumber = existingForProject + 1
        let existingXPositions = sessions.values.map(\.spriteXPosition)
        let session = SessionData(sessionId: sessionId, cwd: cwd, sessionNumber: sessionNumber, isInteractive: isInteractive, existingXPositions: existingXPositions)
        sessions[sessionId] = session
        logger.info("Created session #\(sessionNumber): \(sessionId, privacy: .public) at \(cwd, privacy: .public)")

        if activeSessionCount == 1 {
            selectedSessionId = sessionId
        } else {
            selectedSessionId = nil
        }

        return session
    }

    private func removeSession(_ sessionId: String) {
        sessions.removeValue(forKey: sessionId)
        logger.info("Removed session: \(sessionId, privacy: .public)")

        if selectedSessionId == sessionId {
            selectedSessionId = nil
        }

        if activeSessionCount == 1 {
            selectedSessionId = sessions.keys.first
        }
    }

    func dismissSession(_ sessionId: String) {
        sessions[sessionId]?.endSession()
        removeSession(sessionId)
        schedulePersist()
    }

    func resolvePermission(sessionId: String, decision: String, reason: String? = nil) {
        guard let session = sessions[sessionId],
              let pending = session.pendingResponse else { return }

        var responseDict: [String: Any] = ["decision": decision]
        if let reason { responseDict["reason"] = reason }

        if let data = try? JSONSerialization.data(withJSONObject: responseDict) {
            let fd = pending.clientSocket
            DispatchQueue.global(qos: .userInitiated).async {
                SocketServer.sendResponse(data, to: fd)
            }
        }

        session.setPendingResponse(nil)
        session.clearPendingQuestions()
        if decision == "allow" {
            session.updateTask(.working)
        } else {
            session.updateTask(.idle)
        }
        schedulePersist()
    }

    private var responseTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var autoRemovalTasks: [String: Task<Void, Never>] = [:]

    private func scheduleResponseTimeout(sessionId: String) {
        responseTimeoutTasks[sessionId]?.cancel()
        responseTimeoutTasks[sessionId] = Task {
            try? await Task.sleep(for: .seconds(85))
            guard !Task.isCancelled else { return }
            guard let session = sessions[sessionId],
                  session.pendingResponse != nil else { return }
            // Timed out — close socket, Claude Code falls through to terminal
            if let pending = session.pendingResponse {
                let fd = pending.clientSocket
                DispatchQueue.global(qos: .utility).async { close(fd) }
            }
            session.setPendingResponse(nil)
        }
    }

    private func scheduleAutoRemoval(sessionId: String, delay: Int) {
        autoRemovalTasks[sessionId]?.cancel()
        autoRemovalTasks[sessionId] = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            // Only remove if still sleeping (not reactivated by a new hook)
            guard let session = sessions[sessionId], session.task == .sleeping else { return }
            dismissSession(sessionId)
            autoRemovalTasks.removeValue(forKey: sessionId)
        }
    }

    private static func parseQuestions(from toolInput: [String: AnyCodable]?) -> [PendingQuestion] {
        guard let input = toolInput?.mapValues({ $0.value }) else { return [] }

        // Format 1: Claude Code built-in — {"questions": [{"question": "...", "options": [{...}]}]}
        if let questions = input["questions"] as? [[String: Any]] {
            return questions.compactMap { q in
                guard let questionText = q["question"] as? String else { return nil }
                let header = q["header"] as? String
                let options = parseOptions(from: q["options"])
                return PendingQuestion(question: questionText, header: header, options: options)
            }
        }

        // Format 2: MCP / Conductor — {"question": "...", "options": [...]}
        if let questionText = input["question"] as? String {
            let options = parseOptions(from: input["options"])
            return [PendingQuestion(question: questionText, header: "Question", options: options)]
        }

        return []
    }

    private static func parseOptions(from raw: Any?) -> [(label: String, description: String?)] {
        // Handle array of dicts: [{"label": "...", "description": "..."}]
        if let dictOptions = raw as? [[String: Any]] {
            return dictOptions.compactMap { opt in
                guard let label = opt["label"] as? String else { return nil }
                return (label: label, description: opt["description"] as? String)
            }
        }
        // Handle array of strings: ["Option 1", "Option 2"]
        if let stringOptions = raw as? [String] {
            return stringOptions.map { (label: $0, description: nil) }
        }
        return []
    }

    private static let localSlashCommands: Set<String> = [
        "/clear", "/help", "/cost", "/status",
        "/vim", "/fast", "/model", "/login", "/logout",
    ]

    private static func isLocalSlashCommand(_ prompt: String?) -> Bool {
        guard let prompt, prompt.hasPrefix("/") else { return false }
        let command = String(prompt.prefix(while: { !$0.isWhitespace }))
        return localSlashCommands.contains(command)
    }

    private static func isAskUserQuestion(_ tool: String?) -> Bool {
        guard let tool else { return false }
        return tool == "AskUserQuestion" || tool.hasSuffix("AskUserQuestion")
    }

    /// Tools that modify state and should prompt for user approval in restricted modes.
    private static let permissionRequiredTools: Set<String> = [
        "Write", "Edit", "Bash", "NotebookEdit",
        "MultiEdit", "TodoWrite",
    ]

    /// Read-only tools that never need approval.
    private static let safeTools: Set<String> = [
        "Read", "Glob", "Grep", "WebFetch", "WebSearch",
        "LSP", "Agent", "TaskCreate", "TaskUpdate", "TaskGet", "TaskList",
    ]

    private static func needsPermissionApproval(tool: String?, permissionMode: String) -> Bool {
        guard let tool else { return false }

        // In permissive modes, never block
        if permissionMode == "dontAsk" || permissionMode == "bypassPermissions" {
            return false
        }

        // MCP tools (prefixed) — always prompt in plan/default mode
        if tool.contains("__") && !isAskUserQuestion(tool) {
            // MCP tool — prompt unless it's a known safe pattern
            return permissionMode == "plan" || permissionMode == "default"
        }

        // Known safe tools — never prompt
        if safeTools.contains(tool) { return false }

        // Known dangerous tools — prompt in plan/default mode
        if permissionRequiredTools.contains(tool) {
            return permissionMode == "plan" || permissionMode == "default" || permissionMode == "acceptEdits"
        }

        // Unknown tools — prompt in plan mode only
        return permissionMode == "plan"
    }

    private static func respondAllow(to clientSocket: Int32) {
        let response: [String: Any] = ["decision": "allow"]
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            DispatchQueue.global(qos: .userInitiated).async {
                SocketServer.sendResponse(data, to: clientSocket)
            }
        } else {
            DispatchQueue.global(qos: .utility).async { close(clientSocket) }
        }
    }

    private static func buildPermissionQuestion(tool: String?, toolInput: [String: AnyCodable]?) -> PendingQuestion {
        let toolName = tool ?? "Tool"
        let input = toolInput?.mapValues { $0.value }
        let description = SessionEvent.deriveDescription(tool: tool, toolInput: input)
        return PendingQuestion(
            question: description ?? "\(toolName) wants to proceed",
            header: "Permission Request",
            // Claude Code permission prompts always present these three choices
            options: [
                (label: "Yes", description: nil),
                (label: "Yes, and don't ask again", description: nil),
                (label: "No", description: nil),
            ]
        )
    }

    // MARK: - Persistence

    private static let persistURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("rhythm")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }()

    private var persistTask: Task<Void, Never>?

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            persistSessions()
        }
    }

    private func persistSessions() {
        let persisted = sessions.values.map { $0.toPersisted() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(persisted) else {
            logger.error("Failed to encode sessions for persistence")
            return
        }
        do {
            try data.write(to: Self.persistURL, options: .atomic)
            DiagLog.shared.write("SESSION: Persisted \(persisted.count) sessions to disk")
            logger.debug("Persisted \(persisted.count) sessions")
        } catch {
            logger.error("Failed to write sessions: \(error.localizedDescription)")
        }
    }

    func restoreSessions() {
        DiagLog.shared.write("SESSION: Restoring from \(Self.persistURL.path)")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Self.persistURL),
              let persisted = try? decoder.decode([SessionData.Persisted].self, from: data) else {
            DiagLog.shared.write("SESSION: No persisted sessions found (file missing or decode failed)")
            logger.info("No persisted sessions to restore")
            return
        }
        DiagLog.shared.write("SESSION: Found \(persisted.count) persisted sessions")

        var restoredCount = 0
        for entry in persisted {
            // Skip if session already exists (from a hook event that arrived first)
            guard sessions[entry.sessionId] == nil else { continue }

            // Check if the process is still alive
            let alive: Bool
            if let pid = entry.pid {
                alive = kill(Int32(pid), 0) == 0
            } else {
                // No PID — check if session file was modified recently (last 2 hours)
                let sessionFile = ConversationParser.sessionFilePath(
                    sessionId: entry.sessionId, cwd: entry.cwd
                )
                if let attrs = try? FileManager.default.attributesOfItem(atPath: sessionFile),
                   let modified = attrs[.modificationDate] as? Date {
                    alive = Date().timeIntervalSince(modified) < 7200
                } else {
                    alive = false
                }
            }

            let existingXPositions = sessions.values.map(\.spriteXPosition)
            let session = SessionData(restoring: entry, existingXPositions: existingXPositions)
            sessions[entry.sessionId] = session

            // Session numbers are now computed from active count, no need to track max

            if alive {
                // Process still running — reset transient states to .idle so the
                // session wakes on the next hook event. Covers sessions that went
                // sleeping or compacting due to inactivity and were persisted that way.
                let restoredTask = RhythmTask(rawValue: entry.task ?? "") ?? .idle
                if restoredTask == .working || restoredTask == .waiting
                    || restoredTask == .compacting || restoredTask == .sleeping {
                    session.updateTask(.idle)
                } else {
                    session.updateTask(restoredTask)
                }
            } else {
                // Skip dead sessions older than 1 hour
                let age = Date().timeIntervalSince(entry.lastActivity)
                if age > 3600 {
                    DiagLog.shared.write("SESSION: Expired #\(entry.sessionNumber) — inactive for \(Int(age))s")
                    sessions.removeValue(forKey: entry.sessionId)
                    continue
                }
                session.updateTask(.sleeping)
            }

            restoredCount += 1
            DiagLog.shared.write("SESSION: Restored #\(entry.sessionNumber) id=\(entry.sessionId.prefix(8))... cwd=\(entry.cwd) pid=\(entry.pid ?? -1) alive=\(alive)")
            logger.info("Restored session #\(entry.sessionNumber): \(entry.sessionId, privacy: .public) (alive: \(alive))")
        }

        if restoredCount > 0 {
            logger.info("Restored \(restoredCount) sessions from disk")
            // Auto-select if only one
            if sessions.count == 1 {
                selectedSessionId = sessions.keys.first
            }
        }
    }

    func startLivenessPolling() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                for session in sessions.values {
                    if let pid = session.pid {
                        let alive = kill(Int32(pid), 0) == 0
                        if !alive && session.task != .sleeping {
                            session.updateTask(.sleeping)
                            session.updateProcessingState(isProcessing: false)
                            // Schedule removal — process is dead, no SessionEnd will arrive
                            scheduleAutoRemoval(sessionId: session.id, delay: 30)
                            schedulePersist()
                        }
                    }
                }
            }
        }
    }
}

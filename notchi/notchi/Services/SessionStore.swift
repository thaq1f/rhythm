import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SessionStore")

@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [String: SessionData] = [:]
    private(set) var selectedSessionId: String?
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

    func process(_ event: HookEvent) -> SessionData {
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
            if event.tool == "AskUserQuestion" {
                session.updateTask(.waiting)
                session.setPendingQuestions(Self.parseQuestions(from: event.toolInput))
            } else {
                session.clearPendingQuestions()
                session.updateTask(.working)
            }

        case "PermissionRequest":
            let question = Self.buildPermissionQuestion(tool: event.tool, toolInput: event.toolInput)
            session.updateTask(.waiting)
            session.setPendingQuestions([question])

        case "PostToolUse":
            let success = event.status != "error"
            session.recordPostToolUse(tool: event.tool, toolUseId: event.toolUseId, success: success)
            session.clearPendingQuestions()
            session.updateTask(.working)

        case "Stop", "SubagentStop":
            session.clearPendingQuestions()
            session.updateTask(.idle)

        case "SessionEnd":
            // Keep session visible as sleeping sprite (like a tab).
            // Only removed when user explicitly dismisses it.
            session.updateTask(.sleeping)
            session.updateProcessingState(isProcessing: false)

        default:
            if !isProcessing && session.task != .idle {
                session.updateTask(.idle)
            }
        }

        schedulePersist()
        return session
    }

    func recordAssistantMessages(_ messages: [AssistantMessage], for sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        session.recordAssistantMessages(messages)
    }

    private func getOrCreateSession(sessionId: String, cwd: String, isInteractive: Bool) -> SessionData {
        if let existing = sessions[sessionId] {
            return existing
        }

        let projectName = (cwd as NSString).lastPathComponent
        let sessionNumber = nextSessionNumberByProject[projectName, default: 0] + 1
        nextSessionNumberByProject[projectName] = sessionNumber
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

    private static func parseQuestions(from toolInput: [String: AnyCodable]?) -> [PendingQuestion] {
        guard let input = toolInput?.mapValues({ $0.value }),
              let questions = input["questions"] as? [[String: Any]] else { return [] }

        return questions.compactMap { q in
            guard let questionText = q["question"] as? String else { return nil }
            let header = q["header"] as? String
            let rawOptions = q["options"] as? [[String: Any]] ?? []
            let options = rawOptions.compactMap { opt -> (label: String, description: String?)? in
                guard let label = opt["label"] as? String else { return nil }
                return (label: label, description: opt["description"] as? String)
            }
            return PendingQuestion(question: questionText, header: header, options: options)
        }
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
        let dir = appSupport.appendingPathComponent("notchi")
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

            // Track session numbers for this project
            let projectName = (entry.cwd as NSString).lastPathComponent
            let current = nextSessionNumberByProject[projectName, default: 0]
            if entry.sessionNumber > current {
                nextSessionNumberByProject[projectName] = entry.sessionNumber
            }

            if !alive {
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
}

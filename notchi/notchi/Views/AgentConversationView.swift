import SwiftUI

/// Renders a live conversation with a spawned agent.
/// Tool calls are rendered like Rhythm's activity view (icon + name + status badge).
struct AgentConversationView: View {
    let agentSession: AgentSessionManager
    let voiceOrchestrator: VoiceOrchestrator

    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if let error = agentSession.error {
                errorBanner(error)
            }
            Divider().background(Color.white.opacity(0.08))
            inputBar
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(agentSession.messages) { msg in
                        messageRow(msg).id(msg.id)
                    }

                    // Live streaming text
                    if !agentSession.streamingText.isEmpty {
                        agentTextBubble(agentSession.streamingText, isStreaming: true)
                            .id("streaming")
                    }

                    // Active tool indicator
                    if let toolName = agentSession.activeToolName {
                        toolRunningRow(toolName).id("active-tool")
                    }

                    // Processing spinner (no text yet)
                    if agentSession.isProcessing
                        && agentSession.streamingText.isEmpty
                        && agentSession.activeToolName == nil {
                        thinkingRow.id("thinking")
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
            .onChange(of: agentSession.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: agentSession.streamingText) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let target: String
        if !agentSession.streamingText.isEmpty {
            target = "streaming"
        } else if agentSession.activeToolName != nil {
            target = "active-tool"
        } else if let last = agentSession.messages.last {
            target = last.id.uuidString
        } else {
            return
        }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    // MARK: - Message Rows

    @ViewBuilder
    private func messageRow(_ msg: ConversationMessage) -> some View {
        switch msg.role {
        case .user:
            userBubble(msg.content)
        case .agent:
            agentTextBubble(msg.content, isStreaming: false)
        case .system:
            systemRow(msg.content)
        case .toolUse(let name):
            toolUseRow(name: name)
        case .toolResult(let name):
            toolResultRow(name: name, output: msg.content)
        case .thinking:
            thinkingRow
        }
    }

    // MARK: - User Bubble

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    // MARK: - Agent Text

    private func agentTextBubble(_ text: String, isStreaming: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 9))
                .foregroundColor(.purple.opacity(0.7))
                .padding(.top, 3)

            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(isStreaming ? 0.8 : 0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    // MARK: - Tool Use (like Rhythm's activity row)

    private func toolUseRow(name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: toolIcon(for: name))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(toolColor(for: name))
                .frame(width: 16)

            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(TerminalColors.primaryText)

            Spacer()

            // Running badge
            HStack(spacing: 3) {
                ProgressView()
                    .scaleEffect(0.4)
                    .tint(TerminalColors.amber)
                Text("Running")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(TerminalColors.amber)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(TerminalColors.amber.opacity(0.12))
            .cornerRadius(4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.03))
        .cornerRadius(6)
        .padding(.horizontal, 4)
    }

    private func toolResultRow(name: String, output: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: toolIcon(for: name))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(toolColor(for: name))
                    .frame(width: 16)

                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.primaryText)

                Spacer()

                Text("Completed")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(TerminalColors.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(TerminalColors.green.opacity(0.12))
                    .cornerRadius(4)
            }

            if !output.isEmpty && output != "Done" {
                Text(output)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(TerminalColors.dimmedText)
                    .lineLimit(4)
                    .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.03))
        .cornerRadius(6)
        .padding(.horizontal, 4)
    }

    private func toolRunningRow(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: toolIcon(for: name))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(toolColor(for: name))
                .frame(width: 16)

            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(TerminalColors.primaryText)

            Spacer()

            HStack(spacing: 3) {
                ProcessingSpinner()
                    .frame(width: 10, height: 10)
                Text("Running")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(TerminalColors.amber)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(TerminalColors.amber.opacity(0.12))
            .cornerRadius(4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.03))
        .cornerRadius(6)
        .padding(.horizontal, 4)
    }

    // MARK: - System / Thinking

    private func systemRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.35))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }

    private var thinkingRow: some View {
        HStack(spacing: 6) {
            ProcessingSpinner()
                .frame(width: 12, height: 12)
            Text("Thinking...")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Error

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
            Text(error)
                .font(.system(size: 10))
                .lineLimit(2)
        }
        .foregroundColor(.red.opacity(0.8))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button(action: { voiceOrchestrator.toggleRecording() }) {
                Image(systemName: voiceOrchestrator.presentationState.currentState.isRecording ? "mic.fill" : "mic")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(
                        voiceOrchestrator.presentationState.currentState.isRecording
                            ? .red : .white.opacity(0.6)
                    )
                    .frame(width: 28, height: 28)
                    .background(
                        voiceOrchestrator.presentationState.currentState.isRecording
                            ? Color.red.opacity(0.2) : Color.white.opacity(0.06)
                    )
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            TextField("Message Claude...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .focused($isInputFocused)
                .onSubmit { sendText() }

            if !inputText.isEmpty {
                Button(action: sendText) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func sendText() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        Task { await agentSession.sendPrompt(text) }
    }

    // MARK: - Tool Styling

    private func toolIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("bash") || lower.contains("terminal") { return "terminal" }
        if lower.contains("read") || lower.contains("file") { return "doc" }
        if lower.contains("write") || lower.contains("edit") { return "pencil" }
        if lower.contains("search") || lower.contains("grep") || lower.contains("glob") { return "magnifyingglass" }
        if lower.contains("web") || lower.contains("fetch") { return "globe" }
        if lower.contains("git") { return "arrow.triangle.branch" }
        if lower.contains("list") || lower.contains("ls") { return "list.bullet" }
        return "wrench"
    }

    private func toolColor(for name: String) -> Color {
        let lower = name.lowercased()
        if lower.contains("bash") { return .orange }
        if lower.contains("read") { return .blue }
        if lower.contains("write") || lower.contains("edit") { return .green }
        if lower.contains("search") || lower.contains("grep") { return .purple }
        if lower.contains("web") { return .cyan }
        return TerminalColors.secondaryText
    }
}

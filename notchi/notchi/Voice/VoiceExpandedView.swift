import SwiftUI

/// Expanded voice content for the Voice tab in the notch panel.
/// Shows a mic button to talk to Claude Code sessions directly.
struct VoiceExpandedView: View {
    let state: VoicePresentationState
    let voiceOrchestrator: VoiceOrchestrator
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            switch state.currentState {
            case .idle:
                idleContent
            case .recording, .agentRecording:
                recordingContent
            case .processing(let hint):
                processingContent(hint: hint)
            case .success:
                successContent
            case .agentThinking(let transcript, let status):
                thinkingContent(transcript: transcript, status: status)
            case .agentResponse(let transcript, let response):
                responseContent(transcript: transcript, response: response)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    // MARK: - Idle: mic button + hint

    private var idleContent: some View {
        VStack(spacing: 16) {
            Spacer()

            // Large mic button
            Button(action: {
                voiceOrchestrator.toggleRecording()
            }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 64, height: 64)
                    Circle()
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 56, height: 56)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            .buttonStyle(.plain)

            Text("Tap to speak to Claude")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            Spacer()
        }
    }

    // MARK: - Recording: waveform + stop button

    private var recordingContent: some View {
        VStack(spacing: 16) {
            Spacer()

            TimelineView(.animation(minimumInterval: 1.0 / 120)) { timeline in
                WaveformView(level: state.audioLevel, time: timeline.date.timeIntervalSinceReferenceDate)
                    .frame(height: 60)
            }

            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(formatDuration(state.duration))
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
            }

            // Stop button
            Button(action: {
                voiceOrchestrator.toggleRecording()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12))
                    Text("Stop")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.8))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    // MARK: - Processing

    private func processingContent(hint: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().scaleEffect(0.8).tint(.white)
            Text(hint)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
            Spacer()
        }
    }

    // MARK: - Success

    private var successContent: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28)).foregroundColor(.green)
            Text("Sent to Claude")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
            Spacer()
        }
    }

    // MARK: - Agent Thinking

    private func thinkingContent(transcript: String, status: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Text(transcript)
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6).tint(.white)
                Text(status).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
            }
            Spacer()
        }
    }

    // MARK: - Agent Response

    private func responseContent(transcript: String, response: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Text(transcript)
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            ScrollView {
                Text(response)
                    .font(.system(size: 12)).foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            HStack(spacing: 8) {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(response, forType: .string)
                }) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.white.opacity(0.08)).clipShape(Capsule())

                Button(action: {
                    AccessibilityService.shared.pasteText(response)
                }) {
                    Label(
                        AccessibilityService.shared.isGranted ? "Paste" : "Enable Paste…",
                        systemImage: AccessibilityService.shared.isGranted ? "doc.on.clipboard" : "lock.shield"
                    )
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.white.opacity(0.08)).clipShape(Capsule())

                Spacer()
                Button(action: { onDismiss?() }) {
                    Text("Dismiss").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
    }
}

// MARK: - Waveform

private struct WaveformView: View {
    let level: Float
    let time: TimeInterval
    private let barCount = 32

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                let phase = time * 3.0 + Double(i) * 0.3
                let wave = Float(0.15 + 0.85 * abs(sin(phase)))
                let height = max(2, CGFloat(level * wave) * 55)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(index: i))
                    .frame(width: 3, height: height)
            }
        }
        .frame(maxWidth: .infinity)
        .drawingGroup()
    }

    private func barColor(index: Int) -> Color {
        let center = barCount / 2
        let distance = abs(index - center)
        let opacity = max(0.3, 1.0 - Double(distance) / Double(center) * 0.7)
        return Color.red.opacity(opacity)
    }
}

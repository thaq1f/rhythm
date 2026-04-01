import SwiftUI

/// Full-width recording / processing bar shown in the expanded panel.
/// Uses the same 120fps TimelineView animation as VoiceCompactView but
/// at a larger size that fits the expanded layout.
struct VoiceRecordingBarView: View {
    let state: VoicePresentationState

    var body: some View {
        Group {
            switch state.currentState {
            case .recording, .agentRecording:
                recordingBar
            case .processing, .agentThinking:
                processingBar
            case .success:
                successBar
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9, anchor: .bottom).combined(with: .opacity),
            removal: .opacity.animation(.easeOut(duration: 0.15))
        ))
    }

    // MARK: Recording

    private var recordingBar: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(elapsed * 3.0)

            HStack(spacing: 10) {
                // Pulsing red dot
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .opacity(0.6 + pulse * 0.4)

                // Animated bars — same style as VoiceCompactView but wider
                audioBars(level: state.audioLevel, time: elapsed)

                Spacer()

                // Duration counter
                Text(formatDuration(state.duration))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.red.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.red.opacity(0.2 + pulse * 0.1), lineWidth: 1)
                    )
            )
        }
    }

    @ViewBuilder
    private func audioBars(level: Float, time: TimeInterval) -> some View {
        HStack(spacing: 2.5) {
            ForEach(0..<7, id: \.self) { i in
                let phase = time * 4.0 + Double(i) * 0.55
                let wave = Float(0.3 + 0.7 * abs(sin(phase)))
                let height = max(4, CGFloat(level * wave) * 18)

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 3, height: height)
                    .animation(.easeOut(duration: 0.05), value: height)
            }
        }
        .frame(height: 18)
    }

    // MARK: Processing

    private var processingBar: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            let rotation = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.0) * 360

            HStack(spacing: 8) {
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Color.white.opacity(0.7), lineWidth: 2)
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(rotation))

                if case .processing(let hint) = state.currentState {
                    Text(hint)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.04))
            )
        }
    }

    // MARK: Success

    private var successBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(TerminalColors.green)
            Text("sent")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(TerminalColors.green.opacity(0.8))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(TerminalColors.green.opacity(0.08))
        )
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
    }
}

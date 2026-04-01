import SwiftUI

/// Compact voice indicator for the notch collapsed header (~32pt).
/// Uses TimelineView at native refresh rate (120fps on ProMotion).
struct VoiceCompactView: View {
    let state: VoicePresentationState

    var body: some View {
        Group {
            switch state.currentState {
            case .idle:
                EmptyView()
            case .recording, .agentRecording:
                recordingIndicator
            case .processing, .agentThinking:
                processingIndicator
            case .success:
                successIndicator
            case .agentResponse:
                attentionBadge
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recordingIndicator: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 120)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(elapsed * 3.0)

            HStack(spacing: 3) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                    .opacity(0.6 + pulse * 0.4)

                audioBarsMini(level: state.audioLevel, time: elapsed)

                Text(formatDuration(state.duration))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }

    @ViewBuilder
    private func audioBarsMini(level: Float, time: TimeInterval) -> some View {
        HStack(spacing: 1.5) {
            ForEach(0..<3, id: \.self) { i in
                let phase = time * 4.0 + Double(i) * 0.7
                let wave = Float(0.3 + 0.7 * abs(sin(phase)))
                let height = max(3, CGFloat(level * wave) * 12)

                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.red.opacity(0.9))
                    .frame(width: 2, height: height)
            }
        }
        .frame(height: 12)
    }

    private var processingIndicator: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            let rotation = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0) * 360

            HStack(spacing: 4) {
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .rotationEffect(.degrees(rotation))

                if case .processing(let hint) = state.currentState {
                    Text(hint)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
    }

    private var successIndicator: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 6, height: 6)
    }

    private var attentionBadge: some View {
        HStack(spacing: 3) {
            Circle().fill(Color.blue).frame(width: 5, height: 5)
            Text("reply")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        String(format: "%d:%02d", Int(d) / 60, Int(d) % 60)
    }
}

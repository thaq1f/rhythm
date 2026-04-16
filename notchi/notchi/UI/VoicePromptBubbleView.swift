import SwiftUI

/// Bubble shown in the chat thread immediately after a voice transcription is routed
/// to a Claude Code session. Clears automatically when the UserPromptSubmit hook fires.
struct VoicePromptBubbleView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(TerminalColors.green)
                .padding(.top, 2)

            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(TerminalColors.green.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(TerminalColors.green.opacity(0.25), lineWidth: 1)
                )
        )
    }
}

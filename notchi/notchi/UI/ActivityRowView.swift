import Combine
import SwiftUI

struct ActivityRowView: View {
    let event: SessionEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                bullet
                toolName
                if event.status != .running {
                    statusLabel
                }
            }

            if let description = event.description {
                Text(description)
                    .font(.system(size: 12).italic())
                    .foregroundColor(TerminalColors.dimmedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 13)
            }
        }
        .padding(.vertical, 4)
    }

    private var bullet: some View {
        Circle()
            .fill(bulletColor)
            .frame(width: 5, height: 5)
    }

    private var bulletColor: Color {
        switch event.status {
        case .running: return TerminalColors.amber
        case .success: return TerminalColors.green
        case .error: return TerminalColors.red
        }
    }

    private var toolName: some View {
        Text(event.tool ?? event.type)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(TerminalColors.primaryText)
    }

    private var statusLabel: some View {
        let isSuccess = event.status == .success
        return Text(isSuccess ? "Completed" : "Failed")
            .font(.system(size: 12))
            .foregroundColor(isSuccess ? TerminalColors.secondaryText : TerminalColors.red)
    }
}

struct QuestionPromptView: View {
    let questions: [PendingQuestion]
    let hasPendingResponse: Bool
    let onOptionSelected: ((String) -> Void)?
    @State private var currentIndex = 0
    @State private var hoveredOption: Int?
    @State private var pressedOption: Int?

    init(questions: [PendingQuestion], hasPendingResponse: Bool = false, onOptionSelected: ((String) -> Void)? = nil) {
        self.questions = questions
        self.hasPendingResponse = hasPendingResponse
        self.onOptionSelected = onOptionSelected
    }

    private var clampedIndex: Int {
        min(currentIndex, questions.count - 1)
    }

    private var current: PendingQuestion {
        questions[clampedIndex]
    }

    private var hasMultipleQuestions: Bool {
        questions.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            questionHeader
            questionText
            if hasPendingResponse {
                interactiveOptions
            } else {
                optionsList
            }
            answerHint
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hasPendingResponse ? TerminalColors.claudeOrange.opacity(0.06) : TerminalColors.subtleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(hasPendingResponse ? TerminalColors.claudeOrange.opacity(0.5) : TerminalColors.claudeOrange.opacity(0.3), lineWidth: hasPendingResponse ? 1.5 : 1)
        )
        .padding(.vertical, 4)
        .onChange(of: questions.count) {
            currentIndex = 0
        }
    }

    private var questionHeader: some View {
        HStack {
            if let header = current.header {
                HStack(spacing: 4) {
                    if hasPendingResponse {
                        Circle()
                            .fill(TerminalColors.claudeOrange)
                            .frame(width: 6, height: 6)
                    }
                    Text(header)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(TerminalColors.claudeOrange)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
            }

            if hasMultipleQuestions {
                Text("(\(clampedIndex + 1)/\(questions.count))")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(TerminalColors.secondaryText)
            }

            Spacer()

            if hasMultipleQuestions {
                paginationControls
            }
        }
    }

    private var paginationControls: some View {
        HStack(spacing: 2) {
            Button(action: { currentIndex = max(0, currentIndex - 1) }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(currentIndex > 0 ? TerminalColors.primaryText : TerminalColors.dimmedText)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex == 0)

            Button(action: { currentIndex = min(questions.count - 1, currentIndex + 1) }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(currentIndex < questions.count - 1 ? TerminalColors.primaryText : TerminalColors.dimmedText)
            }
            .buttonStyle(.plain)
            .disabled(currentIndex == questions.count - 1)
        }
    }

    private var questionText: some View {
        Text(current.question)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(TerminalColors.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Interactive options (when Rhythm can respond)

    private var interactiveOptions: some View {
        HStack(spacing: 6) {
            ForEach(Array(current.options.enumerated()), id: \.offset) { index, option in
                Button(action: {
                    withAnimation(.spring(duration: 0.2, bounce: 0.15)) {
                        pressedOption = index
                    }
                    onOptionSelected?(option.label)
                }) {
                    Text(option.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(buttonTextColor(for: option.label))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(buttonBackground(for: option.label, index: index))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(buttonBorderColor(for: option.label, index: index), lineWidth: 1)
                        )
                        .scaleEffect(pressedOption == index ? 0.95 : (hoveredOption == index ? 1.02 : 1.0))
                }
                .buttonStyle(.plain)
                .onHover { isHovered in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        hoveredOption = isHovered ? index : nil
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func buttonTextColor(for label: String) -> Color {
        switch label {
        case "No":
            return TerminalColors.red.opacity(0.9)
        default:
            return .white.opacity(0.95)
        }
    }

    private func buttonBackground(for label: String, index: Int) -> Color {
        let isHovered = hoveredOption == index
        switch label {
        case "Yes":
            return TerminalColors.green.opacity(isHovered ? 0.35 : 0.2)
        case "Yes, and don't ask again":
            return TerminalColors.claudeOrange.opacity(isHovered ? 0.3 : 0.15)
        case "No":
            return TerminalColors.red.opacity(isHovered ? 0.2 : 0.08)
        default:
            return Color.white.opacity(isHovered ? 0.15 : 0.08)
        }
    }

    private func buttonBorderColor(for label: String, index: Int) -> Color {
        let isHovered = hoveredOption == index
        switch label {
        case "Yes":
            return TerminalColors.green.opacity(isHovered ? 0.6 : 0.3)
        case "Yes, and don't ask again":
            return TerminalColors.claudeOrange.opacity(isHovered ? 0.5 : 0.25)
        case "No":
            return TerminalColors.red.opacity(isHovered ? 0.4 : 0.2)
        default:
            return Color.white.opacity(isHovered ? 0.3 : 0.12)
        }
    }

    // MARK: - Static options (read-only display)

    private var optionsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(current.options.enumerated()), id: \.offset) { index, option in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(index + 1).")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundColor(TerminalColors.claudeOrange)
                        .frame(width: 16, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(TerminalColors.primaryText)
                        if let desc = option.description {
                            Text(desc)
                                .font(.system(size: 10))
                                .foregroundColor(TerminalColors.dimmedText)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private var answerHint: some View {
        Group {
            if hasPendingResponse {
                Text("Click to respond from here")
                    .font(.system(size: 10, weight: .medium).italic())
                    .foregroundColor(TerminalColors.claudeOrange.opacity(0.8))
            } else {
                Text("Answer in terminal")
                    .font(.system(size: 10).italic())
                    .foregroundColor(TerminalColors.dimmedText)
            }
        }
    }
}

struct WorkingIndicatorView: View {
    let state: NotchiState
    @State private var dotCount = 1
    @State private var symbolPhase = 0

    private let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let dotsTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    private let symbolTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    private var dots: String {
        String(repeating: ".", count: dotCount)
    }

    private var statusText: String {
        switch state.task {
        case .compacting: return "Compacting"
        case .waiting:    return "Waiting"
        default:          return "Clanking"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(symbols[symbolPhase])
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(TerminalColors.claudeOrange)
                .frame(width: 14, alignment: .center)
            Text("\(statusText)\(dots)")
                .font(.system(size: 12, weight: .medium).italic())
                .foregroundColor(TerminalColors.claudeOrange)
        }
        .padding(.leading, -1)
        .onReceive(dotsTimer) { _ in
            dotCount = (dotCount % 3) + 1
        }
        .onReceive(symbolTimer) { _ in
            symbolPhase = (symbolPhase + 1) % symbols.count
        }
    }
}

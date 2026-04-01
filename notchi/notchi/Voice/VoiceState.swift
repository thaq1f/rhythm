import Observation
import Foundation

/// Presentation state for voice recording in the notch UI.
enum VoiceState: Equatable {
    case idle
    case recording
    case processing(hint: String)
    case success
    case agentRecording
    case agentThinking(transcript: String, status: String)
    case agentResponse(transcript: String, response: String)

    var isRecording: Bool {
        switch self {
        case .recording, .agentRecording: return true
        default: return false
        }
    }

    var isAgentExpanded: Bool {
        switch self {
        case .agentThinking, .agentResponse: return true
        default: return false
        }
    }

    var isProcessing: Bool {
        switch self {
        case .processing: return true
        default: return false
        }
    }

    var isVisible: Bool { self != .idle }

    static func == (lhs: VoiceState, rhs: VoiceState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.recording, .recording): return true
        case (.processing(let a), .processing(let b)): return a == b
        case (.success, .success): return true
        case (.agentRecording, .agentRecording): return true
        case (.agentThinking(let a1, let a2), .agentThinking(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.agentResponse(let a1, let a2), .agentResponse(let b1, let b2)): return a1 == b1 && a2 == b2
        default: return false
        }
    }
}

/// Observable voice presentation state for compact and expanded views.
@MainActor
@Observable
final class VoicePresentationState {
    var currentState: VoiceState = .idle
    var duration: TimeInterval = 0
    var audioLevel: Float = 0

    func reset() {
        currentState = .idle
        duration = 0
        audioLevel = 0
    }
}

import Foundation

enum NotchiTask: String, CaseIterable {
    case idle, working, sleeping, compacting, waiting

    var animationFPS: Double {
        switch self {
        case .compacting: return 6.0
        case .sleeping: return 2.0
        default: return 4.0
        }
    }

    var spritePrefix: String {
        switch self {
        case .waiting: return "compacting"
        default: return rawValue
        }
    }

    var bobDuration: Double {
        switch self {
        case .sleeping:   return 4.0
        case .idle, .waiting: return 1.5
        case .working:    return 0.4
        case .compacting: return 0.5
        }
    }

    var bobAmplitude: CGFloat {
        switch self {
        case .sleeping, .compacting: return 0
        case .idle, .waiting:        return 1.5
        case .working:               return 0.5
        }
    }

    var canWalk: Bool {
        switch self {
        case .sleeping, .compacting, .waiting:
            return false
        case .idle, .working:
            return true
        }
    }

    var displayName: String {
        switch self {
        case .idle:       return "Idle"
        case .working:    return "Working..."
        case .sleeping:   return "Sleeping"
        case .compacting: return "Compacting..."
        case .waiting:    return "Waiting..."
        }
    }

    var walkFrequencyRange: ClosedRange<Double> {
        switch self {
        case .sleeping, .waiting: return 30.0...60.0
        case .idle:               return 8.0...15.0
        case .working:            return 5.0...12.0
        case .compacting:         return 15.0...25.0
        }
    }

    var frameCount: Int {
        switch self {
        case .compacting, .waiting: return 5
        default: return 6
        }
    }

    var columns: Int {
        switch self {
        case .compacting, .waiting: return 5
        default: return 6
        }
    }
}

enum NotchiEmotion: String, CaseIterable {
    case neutral, happy, sad

    var swayAmplitude: Double {
        switch self {
        case .neutral: return 0.5
        case .happy:   return 1.0
        case .sad:     return 0.25
        }
    }
}

struct NotchiState: Equatable {
    var task: NotchiTask
    var emotion: NotchiEmotion = .neutral

    var spriteSheetName: String { "\(task.spritePrefix)_\(emotion.rawValue)" }
    var animationFPS: Double { task.animationFPS }
    var bobDuration: Double { task.bobDuration }
    var bobAmplitude: CGFloat { task.bobAmplitude }
    var swayAmplitude: Double { emotion.swayAmplitude }
    var canWalk: Bool { task.canWalk }
    var displayName: String { task.displayName }
    var walkFrequencyRange: ClosedRange<Double> { task.walkFrequencyRange }
    var frameCount: Int { task.frameCount }
    var columns: Int { task.columns }

    static let idle = NotchiState(task: .idle)
    static let working = NotchiState(task: .working)
    static let sleeping = NotchiState(task: .sleeping)
    static let compacting = NotchiState(task: .compacting)
    static let waiting = NotchiState(task: .waiting)
}

import Foundation

struct ExerciseRecord: Decodable, Identifiable {
    let id: UUID
    let name: String
}

struct WorkoutSessionRecord: Decodable, Identifiable {
    let id: UUID
    let status: String
}

struct SavedSetRecord: Decodable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let exerciseID: UUID
    let setNumber: Int
    let weight: Double
    let repsCompleted: Int
    let repsAttempted: Int
    let romPassRate: Double?
    let isPR: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case exerciseID = "exercise_id"
        case setNumber = "set_number"
        case weight
        case repsCompleted = "reps_completed"
        case repsAttempted = "reps_attempted"
        case romPassRate = "rom_pass_rate"
        case isPR = "is_pr"
    }
}

struct LineRecord: Decodable, Identifiable {
    let id: UUID
    let predictedWeight: Double
    let predictedReps: Int
    let confidence: Double
    let baselineSessions: Int
    let version: Int

    enum CodingKeys: String, CodingKey {
        case id
        case predictedWeight = "predicted_weight"
        case predictedReps = "predicted_reps"
        case confidence
        case baselineSessions = "baseline_sessions"
        case version
    }

    var performanceLine: PerformanceLine {
        PerformanceLine(weight: predictedWeight, reps: predictedReps)
    }
}

struct LineEnvelope: Decodable {
    let line: LineRecord?
    let baseline: Bool?
    let sessionsRemaining: Int?

    enum CodingKeys: String, CodingKey {
        case line
        case baseline
        case sessionsRemaining = "sessions_remaining"
    }
}

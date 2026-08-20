import Foundation

/// Product-facing workout operations. Keeps the prototype view free of raw
/// Supabase table/function details and gives us one place to tighten the API later.
enum WorkoutService {
    private static let client = SupabaseConfig.client

    private struct NewSession: Encodable {
        let userID: UUID

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
        }
    }

    private struct CompleteSession: Encodable {
        let status: String
        let endedAt: String

        enum CodingKeys: String, CodingKey {
            case status
            case endedAt = "ended_at"
        }
    }

    private struct SaveSetRequest: Encodable {
        let sessionID: UUID
        let exerciseID: UUID
        let setNumber: Int
        let weight: Double
        let repsCompleted: Int
        let repsAttempted: Int
        let romPassRate: Double
        let startedAt: String
        let endedAt: String

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case exerciseID = "exercise_id"
            case setNumber = "set_number"
            case weight
            case repsCompleted = "reps_completed"
            case repsAttempted = "reps_attempted"
            case romPassRate = "rom_pass_rate"
            case startedAt = "started_at"
            case endedAt = "ended_at"
        }
    }

    private struct SaveSetEnvelope: Decodable {
        let set: SavedSetRecord
    }

    private struct ExerciseLookup: Decodable {
        let id: UUID
    }

    static func exerciseID(named name: String) async throws -> UUID {
        let exercise: ExerciseLookup = try await client
            .from("exercises")
            .select("id")
            .eq("name", value: name)
            .single()
            .execute()
            .value

        return exercise.id
    }

    static func startSession(userID: UUID) async throws -> UUID {
        let session: WorkoutSessionRecord = try await client
            .from("workout_sessions")
            .insert(NewSession(userID: userID))
            .select("id,status")
            .single()
            .execute()
            .value

        return session.id
    }

    static func completeSession(id: UUID, at date: Date = Date()) async throws {
        try await client
            .from("workout_sessions")
            .update(CompleteSession(status: "completed", endedAt: isoString(date)))
            .eq("id", value: id)
            .execute()
    }

    static func saveVerifiedSet(
        sessionID: UUID,
        exerciseID: UUID,
        setNumber: Int,
        weight: Double,
        repsCompleted: Int,
        repsAttempted: Int,
        startedAt: Date,
        endedAt: Date
    ) async throws -> SavedSetRecord {
        let passRate = repsAttempted > 0
            ? (Double(repsCompleted) / Double(repsAttempted)) * 100
            : 0

        let request = SaveSetRequest(
            sessionID: sessionID,
            exerciseID: exerciseID,
            setNumber: setNumber,
            weight: weight,
            repsCompleted: repsCompleted,
            repsAttempted: repsAttempted,
            romPassRate: passRate,
            startedAt: isoString(startedAt),
            endedAt: isoString(endedAt)
        )

        let response: SaveSetEnvelope = try await APIService.invoke("save-set", body: request)
        return response.set
    }

    static func getLine(exerciseID: UUID) async throws -> LineEnvelope {
        try await APIService.invokeGET(
            "get-line",
            query: [URLQueryItem(name: "exercise_id", value: exerciseID.uuidString)]
        )
    }

    @discardableResult
    static func recalculateLine(exerciseID: UUID) async throws -> LineEnvelope {
        struct Request: Encodable { let exercise_id: UUID }
        return try await APIService.invoke(
            "calculate-line",
            body: Request(exercise_id: exerciseID)
        )
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

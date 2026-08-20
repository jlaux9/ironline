import Foundation

struct FirstPlayableSetRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let recordedAt: Date
    let testerID: String?
    let testSessionID: UUID?
    let weight: Double
    let ironVerifiedReps: Int
    let ironNoReps: Int
    let ironTrackingGaps: Int
    let humanCompletedReps: Int
    let humanShallowNoReps: Int
    let agreedWithEveryNoRepCall: Bool?
    let lineMadeUserPushHarder: Bool?
    let lineScorePercent: Double

    init(
        id: UUID = UUID(),
        recordedAt: Date = Date(),
        testerID: String? = nil,
        testSessionID: UUID? = nil,
        weight: Double,
        ironVerifiedReps: Int,
        ironNoReps: Int,
        ironTrackingGaps: Int,
        humanCompletedReps: Int,
        humanShallowNoReps: Int,
        agreedWithEveryNoRepCall: Bool?,
        lineMadeUserPushHarder: Bool?,
        lineScorePercent: Double
    ) {
        self.id = id
        self.recordedAt = recordedAt
        // The existing debrief does not need extra taps: every saved set is
        // automatically stamped with the active Phase 1 tester/session selected
        // from the dashboard. Explicit values still make tests/imports deterministic.
        self.testerID = testerID ?? FirstPlayableTestStore.currentTesterID()
        self.testSessionID = testSessionID ?? FirstPlayableTestStore.currentSessionID()
        self.weight = weight
        self.ironVerifiedReps = max(0, ironVerifiedReps)
        self.ironNoReps = max(0, ironNoReps)
        self.ironTrackingGaps = max(0, ironTrackingGaps)
        self.humanCompletedReps = max(0, humanCompletedReps)
        self.humanShallowNoReps = max(0, humanShallowNoReps)
        self.agreedWithEveryNoRepCall = agreedWithEveryNoRepCall
        self.lineMadeUserPushHarder = lineMadeUserPushHarder
        self.lineScorePercent = lineScorePercent
    }

    var humanAttempts: Int { humanCompletedReps + humanShallowNoReps }
    var ironResolvedAttempts: Int { ironVerifiedReps + ironNoReps }

    var matchedAttemptClassifications: Int {
        min(ironVerifiedReps, humanCompletedReps) + min(ironNoReps, humanShallowNoReps)
    }

    var agreementDenominator: Int { max(humanAttempts, ironResolvedAttempts) }

    var repCountAgreement: Double {
        guard agreementDenominator > 0 else { return 1 }
        return Double(matchedAttemptClassifications) / Double(agreementDenominator)
    }

    var potentialFalseNoReps: Int { max(0, ironNoReps - humanShallowNoReps) }
    var missedShallowNoReps: Int { max(0, humanShallowNoReps - ironNoReps) }
}

struct FirstPlayableTesterProgress: Equatable, Identifiable {
    let testerID: String
    let setCount: Int
    let sessionCount: Int

    var id: String { testerID }
    var meetsCoverageGate: Bool { setCount >= 5 && sessionCount >= 2 }
}

struct FirstPlayableTestSummary: Equatable {
    let setCount: Int
    let totalHumanAttempts: Int
    let totalIronResolvedAttempts: Int
    let totalTrackingGaps: Int
    let setsWithTrackingGaps: Int
    let potentialFalseNoReps: Int
    let missedShallowNoReps: Int
    let repCountAgreement: Double
    let noRepTrustRate: Double?
    let linePushRate: Double?
    let testerProgress: [FirstPlayableTesterProgress]
    let unlabeledSetCount: Int

    var meetsRepAgreementGate: Bool { repCountAgreement >= 0.90 }

    /// Canonical protocol coverage: two testers, five sets each, across at least
    /// two separate sessions per tester.
    var meetsProtocolCoverageGate: Bool {
        testerProgress.filter(\.meetsCoverageGate).count >= 2
    }
}

struct FirstPlayableTestLedger: Codable, Equatable {
    private(set) var records: [FirstPlayableSetRecord] = []

    mutating func append(_ record: FirstPlayableSetRecord) { records.append(record) }

    mutating func replace(_ record: FirstPlayableSetRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else {
            records.append(record)
            return
        }
        records[index] = record
    }

    var summary: FirstPlayableTestSummary {
        let humanAttempts = records.reduce(0) { $0 + $1.humanAttempts }
        let ironAttempts = records.reduce(0) { $0 + $1.ironResolvedAttempts }
        let trackingGaps = records.reduce(0) { $0 + $1.ironTrackingGaps }
        let setsWithTrackingGaps = records.filter { $0.ironTrackingGaps > 0 }.count
        let falseNoRepRisks = records.reduce(0) { $0 + $1.potentialFalseNoReps }
        let missedNoReps = records.reduce(0) { $0 + $1.missedShallowNoReps }

        let matchedClassifications = records.reduce(0) { $0 + $1.matchedAttemptClassifications }
        let agreementDenominator = records.reduce(0) { $0 + $1.agreementDenominator }
        let agreement = agreementDenominator == 0
            ? 1
            : Double(matchedClassifications) / Double(agreementDenominator)

        let noRepAnswers = records.compactMap(\.agreedWithEveryNoRepCall)
        let noRepTrustRate = noRepAnswers.isEmpty
            ? nil
            : Double(noRepAnswers.filter { $0 }.count) / Double(noRepAnswers.count)

        let pushAnswers = records.compactMap(\.lineMadeUserPushHarder)
        let linePushRate = pushAnswers.isEmpty
            ? nil
            : Double(pushAnswers.filter { $0 }.count) / Double(pushAnswers.count)

        let labeledRecords = records.filter { record in
            guard let testerID = record.testerID else { return false }
            return !testerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let testerIDs = Set(labeledRecords.compactMap(\.testerID)).sorted()
        let testerProgress = testerIDs.map { testerID in
            let testerRecords = labeledRecords.filter { $0.testerID == testerID }
            return FirstPlayableTesterProgress(
                testerID: testerID,
                setCount: testerRecords.count,
                sessionCount: Set(testerRecords.compactMap(\.testSessionID)).count
            )
        }

        return FirstPlayableTestSummary(
            setCount: records.count,
            totalHumanAttempts: humanAttempts,
            totalIronResolvedAttempts: ironAttempts,
            totalTrackingGaps: trackingGaps,
            setsWithTrackingGaps: setsWithTrackingGaps,
            potentialFalseNoReps: falseNoRepRisks,
            missedShallowNoReps: missedNoReps,
            repCountAgreement: agreement,
            noRepTrustRate: noRepTrustRate,
            linePushRate: linePushRate,
            testerProgress: testerProgress,
            unlabeledSetCount: records.count - labeledRecords.count
        )
    }
}

enum FirstPlayableTestStore {
    static let storageKey = "ironline.firstPlayable.testLedger.v1"
    static let testerKey = "ironline.firstPlayable.activeTester.v1"
    static let sessionKey = "ironline.firstPlayable.activeSession.v1"

    static func load(defaults: UserDefaults = .standard) -> FirstPlayableTestLedger {
        guard
            let data = defaults.data(forKey: storageKey),
            let ledger = try? JSONDecoder().decode(FirstPlayableTestLedger.self, from: data)
        else { return FirstPlayableTestLedger() }
        return ledger
    }

    static func save(_ ledger: FirstPlayableTestLedger, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func currentTesterID(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: testerKey) ?? "A"
    }

    static func setCurrentTesterID(_ testerID: String, defaults: UserDefaults = .standard) {
        defaults.set(testerID, forKey: testerKey)
    }

    static func currentSessionID(defaults: UserDefaults = .standard) -> UUID {
        if let raw = defaults.string(forKey: sessionKey), let id = UUID(uuidString: raw) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: sessionKey)
        return id
    }

    @discardableResult
    static func startNewSession(defaults: UserDefaults = .standard) -> UUID {
        let id = UUID()
        defaults.set(id.uuidString, forKey: sessionKey)
        return id
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

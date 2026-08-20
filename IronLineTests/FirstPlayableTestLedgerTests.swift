import XCTest
@testable import IronLine

final class FirstPlayableTestLedgerTests: XCTestCase {
    func testPerfectAgreementMeetsNinetyPercentGate() {
        var ledger = FirstPlayableTestLedger()
        ledger.append(record(ironVerified: 10, ironNoReps: 2, humanVerified: 10, humanNoReps: 2))

        let summary = ledger.summary

        XCTAssertEqual(summary.repCountAgreement, 1, accuracy: 0.0001)
        XCTAssertTrue(summary.meetsRepAgreementGate)
        XCTAssertEqual(summary.totalHumanAttempts, 12)
        XCTAssertEqual(summary.totalIronResolvedAttempts, 12)
        XCTAssertEqual(summary.potentialFalseNoReps, 0)
        XCTAssertEqual(summary.missedShallowNoReps, 0)
    }

    func testOneClassificationMismatchAcrossTenAttemptsMeetsGate() {
        var ledger = FirstPlayableTestLedger()
        ledger.append(record(ironVerified: 8, ironNoReps: 2, humanVerified: 9, humanNoReps: 1))

        XCTAssertEqual(ledger.summary.repCountAgreement, 0.9, accuracy: 0.0001)
        XCTAssertTrue(ledger.summary.meetsRepAgreementGate)
        XCTAssertEqual(ledger.summary.potentialFalseNoReps, 1)
        XCTAssertEqual(ledger.summary.missedShallowNoReps, 0)
    }

    func testTwoClassificationMismatchesAcrossTenAttemptsFailsGate() {
        var ledger = FirstPlayableTestLedger()
        ledger.append(record(ironVerified: 7, ironNoReps: 3, humanVerified: 9, humanNoReps: 1))

        XCTAssertEqual(ledger.summary.repCountAgreement, 0.8, accuracy: 0.0001)
        XCTAssertFalse(ledger.summary.meetsRepAgreementGate)
        XCTAssertEqual(ledger.summary.potentialFalseNoReps, 2)
    }

    func testCompensatingErrorsDoNotLookPerfect() {
        var ledger = FirstPlayableTestLedger()
        ledger.append(record(ironVerified: 8, ironNoReps: 2, humanVerified: 9, humanNoReps: 1))
        ledger.append(record(ironVerified: 10, ironNoReps: 0, humanVerified: 9, humanNoReps: 1))

        XCTAssertEqual(ledger.summary.repCountAgreement, 0.9, accuracy: 0.0001)
        XCTAssertEqual(ledger.summary.potentialFalseNoReps, 1)
        XCTAssertEqual(ledger.summary.missedShallowNoReps, 1)
    }

    func testAttemptCountMismatchPenalizesAgreement() {
        var ledger = FirstPlayableTestLedger()
        ledger.append(record(ironVerified: 8, ironNoReps: 1, humanVerified: 9, humanNoReps: 1))

        XCTAssertEqual(ledger.summary.repCountAgreement, 0.9, accuracy: 0.0001)
        XCTAssertTrue(ledger.summary.meetsRepAgreementGate)
    }

    func testTrackingGapSummaryCountsAffectedSets() {
        var ledger = FirstPlayableTestLedger()
        ledger.append(record(ironVerified: 10, ironNoReps: 0, humanVerified: 10, humanNoReps: 0, trackingGaps: 2))
        ledger.append(record(ironVerified: 8, ironNoReps: 1, humanVerified: 8, humanNoReps: 1, trackingGaps: 0))
        ledger.append(record(ironVerified: 9, ironNoReps: 0, humanVerified: 9, humanNoReps: 0, trackingGaps: 1))

        XCTAssertEqual(ledger.summary.totalTrackingGaps, 3)
        XCTAssertEqual(ledger.summary.setsWithTrackingGaps, 2)
    }

    func testTrustAndCompetitiveTensionRatesIgnoreUnansweredSets() {
        var ledger = FirstPlayableTestLedger()
        ledger.append(record(ironVerified: 10, ironNoReps: 1, humanVerified: 10, humanNoReps: 1, agreed: true, pushed: true))
        ledger.append(record(ironVerified: 8, ironNoReps: 2, humanVerified: 8, humanNoReps: 2, agreed: false, pushed: false))
        ledger.append(record(ironVerified: 9, ironNoReps: 0, humanVerified: 9, humanNoReps: 0, agreed: nil, pushed: nil))

        XCTAssertEqual(ledger.summary.noRepTrustRate, 0.5)
        XCTAssertEqual(ledger.summary.linePushRate, 0.5)
    }

    func testProtocolCoverageRequiresTwoTestersFiveSetsAcrossTwoSessionsEach() {
        var ledger = FirstPlayableTestLedger()
        let a1 = UUID(), a2 = UUID(), b1 = UUID(), b2 = UUID()

        for index in 0..<5 {
            ledger.append(record(
                ironVerified: 10,
                ironNoReps: 0,
                humanVerified: 10,
                humanNoReps: 0,
                testerID: "A",
                sessionID: index < 3 ? a1 : a2
            ))
        }
        XCTAssertFalse(ledger.summary.meetsProtocolCoverageGate)

        for index in 0..<5 {
            ledger.append(record(
                ironVerified: 10,
                ironNoReps: 0,
                humanVerified: 10,
                humanNoReps: 0,
                testerID: "B",
                sessionID: index < 3 ? b1 : b2
            ))
        }

        XCTAssertTrue(ledger.summary.meetsProtocolCoverageGate)
        XCTAssertEqual(ledger.summary.testerProgress.count, 2)
        XCTAssertTrue(ledger.summary.testerProgress.allSatisfy(\.meetsCoverageGate))
    }

    func testFiveSetsInOneSessionDoesNotMeetTesterCoverage() {
        var ledger = FirstPlayableTestLedger()
        let session = UUID()

        for _ in 0..<5 {
            ledger.append(record(
                ironVerified: 10,
                ironNoReps: 0,
                humanVerified: 10,
                humanNoReps: 0,
                testerID: "A",
                sessionID: session
            ))
        }

        XCTAssertEqual(ledger.summary.testerProgress.first?.setCount, 5)
        XCTAssertEqual(ledger.summary.testerProgress.first?.sessionCount, 1)
        XCTAssertFalse(ledger.summary.testerProgress.first?.meetsCoverageGate ?? true)
    }

    func testActiveTesterAndSessionConfigurationPersist() throws {
        let suiteName = "FirstPlayableConfigTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        FirstPlayableTestStore.setCurrentTesterID("B", defaults: defaults)
        let firstSession = FirstPlayableTestStore.currentSessionID(defaults: defaults)
        let secondSession = FirstPlayableTestStore.startNewSession(defaults: defaults)

        XCTAssertEqual(FirstPlayableTestStore.currentTesterID(defaults: defaults), "B")
        XCTAssertNotEqual(firstSession, secondSession)
        XCTAssertEqual(FirstPlayableTestStore.currentSessionID(defaults: defaults), secondSession)
    }

    func testLedgerRoundTripsThroughLocalStore() throws {
        let suiteName = "FirstPlayableTestLedgerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var ledger = FirstPlayableTestLedger()
        ledger.append(record(
            ironVerified: 11,
            ironNoReps: 1,
            humanVerified: 11,
            humanNoReps: 1,
            trackingGaps: 2,
            agreed: true,
            pushed: true,
            testerID: "A",
            sessionID: UUID()
        ))

        FirstPlayableTestStore.save(ledger, defaults: defaults)
        let restored = FirstPlayableTestStore.load(defaults: defaults)

        XCTAssertEqual(restored, ledger)
        XCTAssertEqual(restored.summary.totalTrackingGaps, 2)
        XCTAssertEqual(restored.summary.setsWithTrackingGaps, 1)
        XCTAssertEqual(restored.summary.testerProgress.first?.testerID, "A")
    }

    private func record(
        ironVerified: Int,
        ironNoReps: Int,
        humanVerified: Int,
        humanNoReps: Int,
        trackingGaps: Int = 0,
        agreed: Bool? = nil,
        pushed: Bool? = nil,
        testerID: String = "A",
        sessionID: UUID = UUID()
    ) -> FirstPlayableSetRecord {
        FirstPlayableSetRecord(
            testerID: testerID,
            testSessionID: sessionID,
            weight: 70,
            ironVerifiedReps: ironVerified,
            ironNoReps: ironNoReps,
            ironTrackingGaps: trackingGaps,
            humanCompletedReps: humanVerified,
            humanShallowNoReps: humanNoReps,
            agreedWithEveryNoRepCall: agreed,
            lineMadeUserPushHarder: pushed,
            lineScorePercent: 0
        )
    }
}

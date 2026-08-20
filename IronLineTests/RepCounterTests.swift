import XCTest
@testable import IronLine

final class RepCounterTests: XCTestCase {
    func testFullROMRepCounts() {
        var counter = RepCounter()
        let angles: [Double] = [165, 150, 125, 98, 120, 158]
        let events = angles.compactMap { counter.update(angle: $0, confidence: 0.9) }

        XCTAssertEqual(counter.repsCompleted, 1)
        XCTAssertEqual(counter.repsAttempted, 1)
        XCTAssertEqual(events.last, .counted(rep: 1))
    }

    func testShallowAttemptIsNoRep() {
        var counter = RepCounter()
        let angles: [Double] = [165, 145, 125, 118, 140, 160]
        let events = angles.compactMap { counter.update(angle: $0, confidence: 0.9) }

        XCTAssertEqual(counter.repsCompleted, 0)
        XCTAssertEqual(counter.repsAttempted, 1)
        XCTAssertEqual(events.last, .noRep(reason: "INSUFFICIENT ROM"))
    }

    func testLowConfidenceSampleCannotCreateRep() {
        var counter = RepCounter()
        _ = counter.update(angle: 165, confidence: 0.9)
        _ = counter.update(angle: 90, confidence: 0.1)
        _ = counter.update(angle: 160, confidence: 0.9)

        XCTAssertEqual(counter.repsCompleted, 0)
        XCTAssertEqual(counter.repsAttempted, 0)
    }

    func testLowConfidenceMidAttemptInvalidatesRep() {
        var counter = RepCounter()

        _ = counter.update(angle: 165, confidence: 0.9)
        _ = counter.update(angle: 130, confidence: 0.9)
        let event = counter.update(angle: 110, confidence: 0.2)

        XCTAssertEqual(event, .noRep(reason: "TRACKING LOST"))
        XCTAssertEqual(counter.repsCompleted, 0)
        XCTAssertEqual(counter.repsAttempted, 1)

        // A return to lockout only re-arms after the confidence gap.
        XCTAssertNil(counter.update(angle: 160, confidence: 0.9))
        XCTAssertEqual(counter.repsCompleted, 0)
        XCTAssertEqual(counter.repsAttempted, 1)
    }

    func testEnteringFrameAtBottomDoesNotCreateGhostRep() {
        var counter = RepCounter()
        let angles: [Double] = [90, 110, 140, 160, 140, 95, 120, 160]
        for angle in angles {
            _ = counter.update(angle: angle, confidence: 0.9)
        }

        XCTAssertEqual(counter.repsCompleted, 1)
        XCTAssertEqual(counter.repsAttempted, 1)
    }

    func testTrackingLossInvalidatesFullDepthAttemptBeforeLockout() {
        var counter = RepCounter()

        _ = counter.update(angle: 165, confidence: 0.9)
        _ = counter.update(angle: 130, confidence: 0.9)
        _ = counter.update(angle: 95, confidence: 0.9)

        let lossEvent = counter.trackingLost()

        XCTAssertEqual(lossEvent, .noRep(reason: "TRACKING LOST"))
        XCTAssertEqual(counter.repsCompleted, 0)
        XCTAssertEqual(counter.repsAttempted, 1)

        // Reappearing near the bottom and returning to lockout must not finish
        // the interrupted rep. The lockout only re-arms the next attempt.
        _ = counter.update(angle: 100, confidence: 0.9)
        let resumedEvent = counter.update(angle: 160, confidence: 0.9)

        XCTAssertNil(resumedEvent)
        XCTAssertEqual(counter.repsCompleted, 0)
        XCTAssertEqual(counter.repsAttempted, 1)

        // A complete rep observed after the fresh lockout is valid.
        let angles: [Double] = [135, 98, 120, 160]
        let events = angles.compactMap { counter.update(angle: $0, confidence: 0.9) }

        XCTAssertEqual(counter.repsCompleted, 1)
        XCTAssertEqual(counter.repsAttempted, 2)
        XCTAssertEqual(events.last, .counted(rep: 1))
    }

    func testRepeatedTrackingLossDoesNotDoubleCountInterruptedAttempt() {
        var counter = RepCounter()

        _ = counter.update(angle: 165, confidence: 0.9)
        _ = counter.update(angle: 125, confidence: 0.9)

        XCTAssertEqual(counter.trackingLost(), .noRep(reason: "TRACKING LOST"))
        XCTAssertNil(counter.trackingLost())
        XCTAssertNil(counter.trackingLost())

        XCTAssertEqual(counter.repsCompleted, 0)
        XCTAssertEqual(counter.repsAttempted, 1)
    }
}

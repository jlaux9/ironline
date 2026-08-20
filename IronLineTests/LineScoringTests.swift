import XCTest
@testable import IronLine

final class LineScoringTests: XCTestCase {
    func testMatchingLineIsZeroPercent() {
        let line = PerformanceLine(weight: 70, reps: 10)
        let result = LineScoring.score(actualWeight: 70, actualReps: 10, against: line)

        XCTAssertEqual(result.scorePercent, 0, accuracy: 0.0001)
        XCTAssertFalse(result.beatLine)
    }

    func testExtraRepBeatsLine() {
        let line = PerformanceLine(weight: 70, reps: 10)
        let result = LineScoring.score(actualWeight: 70, actualReps: 11, against: line)

        XCTAssertGreaterThan(result.scorePercent, 0)
        XCTAssertTrue(result.beatLine)
    }

    func testInvalidPerformanceDoesNotExplode() {
        let line = PerformanceLine(weight: 0, reps: 0)
        let result = LineScoring.score(actualWeight: 70, actualReps: 10, against: line)

        XCTAssertEqual(result.scorePercent, 0)
    }
}

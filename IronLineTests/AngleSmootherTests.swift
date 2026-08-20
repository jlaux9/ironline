import XCTest
@testable import IronLine

final class AngleSmootherTests: XCTestCase {
    func testMedianRejectsSingleFrameSpike() {
        var smoother = AngleSmoother(windowSize: 5)
        _ = smoother.add(160)
        _ = smoother.add(159)
        _ = smoother.add(40) // bad Vision frame
        _ = smoother.add(161)
        let value = smoother.add(160)

        XCTAssertEqual(value, 160, accuracy: 0.001)
    }
}

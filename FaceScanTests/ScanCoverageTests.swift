import XCTest
@testable import FaceScan

final class ScanCoverageTests: XCTestCase {
    func testEachViewRequiresFourObservationsWithEnoughPoints() {
        var tracker = ScanCoverageTracker()
        observe(&tracker, yaw: 0, pitch: 0, frames: 3)
        XCTAssertTrue(tracker.coveredAngles.isEmpty)
        observe(&tracker, yaw: 0, pitch: 0, points: 249, frames: 8)
        XCTAssertTrue(tracker.coveredAngles.isEmpty)

        observe(&tracker, yaw: 0, pitch: 0, points: 250, frames: 1)
        XCTAssertEqual(tracker.coveredAngles, [.center])
    }

    func testNearAndFarViewsCannotReplaceEachOtherOrOppositeSide() {
        var tracker = ScanCoverageTracker()
        observe(&tracker, yaw: -20, pitch: 0)
        XCTAssertEqual(tracker.coveredAngles, [.left])
        observe(&tracker, yaw: -40, pitch: 0)
        XCTAssertEqual(tracker.coveredAngles, [.left, .farLeft])
        observe(&tracker, yaw: 40, pitch: 0)
        XCTAssertEqual(tracker.coveredAngles, [.left, .farLeft, .farRight])
        observe(&tracker, yaw: 20, pitch: 0)
        XCTAssertEqual(tracker.coveredAngles, [.left, .farLeft, .right, .farRight])
    }

    func testVerticalViewsDoNotAlsoCoverCenter() {
        var tracker = ScanCoverageTracker()
        observe(&tracker, yaw: 0, pitch: 15)
        XCTAssertEqual(tracker.coveredAngles, [.forehead])
        observe(&tracker, yaw: 0, pitch: -15)
        XCTAssertEqual(tracker.coveredAngles, [.forehead, .chin])
        observe(&tracker, yaw: 0, pitch: 0)
        XCTAssertEqual(tracker.coveredAngles, [.center, .forehead, .chin])
    }

    func testCombinedYawAndPitchDoesNotCountAsLevelOrVerticalView() {
        var tracker = ScanCoverageTracker()
        observe(&tracker, yaw: -20, pitch: 15)
        observe(&tracker, yaw: 40, pitch: -15)
        XCTAssertTrue(tracker.coveredAngles.isEmpty)
    }

    func testYawThresholdBoundariesAndGaps() {
        assertCoverage(yaw: 12, pitch: 0, equals: [.center])
        assertCoverage(yaw: -12, pitch: 0, equals: [.center])
        assertCoverage(yaw: 15, pitch: 0, equals: [])
        assertCoverage(yaw: -15, pitch: 0, equals: [])
        assertCoverage(yaw: 18, pitch: 0, equals: [.right])
        assertCoverage(yaw: -18, pitch: 0, equals: [.left])
        assertCoverage(yaw: 30, pitch: 0, equals: [.right])
        assertCoverage(yaw: -30, pitch: 0, equals: [.left])
        assertCoverage(yaw: 31.5, pitch: 0, equals: [])
        assertCoverage(yaw: 33, pitch: 0, equals: [.farRight])
        assertCoverage(yaw: -33, pitch: 0, equals: [.farLeft])
        assertCoverage(yaw: 58, pitch: 0, equals: [.farRight])
        assertCoverage(yaw: -58, pitch: 0, equals: [.farLeft])
        assertCoverage(yaw: 58.1, pitch: 0, equals: [])
        assertCoverage(yaw: -58.1, pitch: 0, equals: [])
    }

    func testPitchBoundariesAndPoseLimits() {
        assertCoverage(yaw: 0, pitch: 9.9, equals: [.center])
        assertCoverage(yaw: 12, pitch: 10, equals: [.forehead])
        assertCoverage(yaw: -12, pitch: -10, equals: [.chin])
        assertCoverage(yaw: 12.1, pitch: 10, equals: [])
        assertCoverage(yaw: 0, pitch: 30, equals: [.forehead])
        assertCoverage(yaw: 0, pitch: -30, equals: [.chin])
        assertCoverage(yaw: 0, pitch: 30.1, equals: [])
        assertCoverage(yaw: 0, pitch: -30.1, equals: [])
    }

    func testNonFinitePosesAreRejected() {
        var tracker = ScanCoverageTracker()
        for _ in 0..<4 {
            tracker.observe(yaw: .nan, pitch: 0, acceptedPoints: 500)
            tracker.observe(yaw: 0, pitch: .nan, acceptedPoints: 500)
            tracker.observe(yaw: .infinity, pitch: 0, acceptedPoints: 500)
            tracker.observe(yaw: 0, pitch: -.infinity, acceptedPoints: 500)
        }
        XCTAssertTrue(tracker.coveredAngles.isEmpty)
    }

    func testHintsFollowGuidedOrderEvenWhenOtherViewsWereObservedFirst() {
        var tracker = ScanCoverageTracker()
        XCTAssertEqual(tracker.nextHint, ScanAngle.center.guidance)
        observe(&tracker, yaw: 40, pitch: 0)
        XCTAssertEqual(tracker.nextHint, ScanAngle.center.guidance)
        observe(&tracker, yaw: 0, pitch: 0)
        XCTAssertEqual(tracker.nextHint, ScanAngle.left.guidance)
        observe(&tracker, yaw: -20, pitch: 0)
        XCTAssertEqual(tracker.nextHint, ScanAngle.farLeft.guidance)
        observe(&tracker, yaw: -40, pitch: 0)
        XCTAssertEqual(tracker.nextHint, ScanAngle.right.guidance)
        observe(&tracker, yaw: 20, pitch: 0)
        XCTAssertEqual(tracker.nextHint, ScanAngle.forehead.guidance)
        observe(&tracker, yaw: 0, pitch: 15)
        XCTAssertEqual(tracker.nextHint, ScanAngle.chin.guidance)
        observe(&tracker, yaw: 0, pitch: -15)
        XCTAssertEqual(tracker.coveredAngles, Set(ScanAngle.allCases))
    }

    func testResetClearsCoveredViewsAndPartialObservationCounts() {
        var tracker = ScanCoverageTracker()
        observe(&tracker, yaw: 0, pitch: 0)
        observe(&tracker, yaw: -20, pitch: 0, frames: 3)
        tracker.reset()
        XCTAssertTrue(tracker.coveredAngles.isEmpty)
        XCTAssertEqual(tracker.nextHint, ScanAngle.center.guidance)
        observe(&tracker, yaw: -20, pitch: 0, frames: 1)
        XCTAssertTrue(tracker.coveredAngles.isEmpty)
    }

    private func observe(_ tracker: inout ScanCoverageTracker, yaw: Float, pitch: Float,
                         points: Int = 250, frames: Int = 4) {
        for _ in 0..<frames {
            tracker.observe(yaw: yaw * .pi / 180, pitch: pitch * .pi / 180,
                            acceptedPoints: points)
        }
    }

    private func assertCoverage(yaw: Float, pitch: Float, equals expected: Set<ScanAngle>,
                                file: StaticString = #filePath, line: UInt = #line) {
        var tracker = ScanCoverageTracker()
        observe(&tracker, yaw: yaw, pitch: pitch)
        XCTAssertEqual(tracker.coveredAngles, expected, file: file, line: line)
    }
}

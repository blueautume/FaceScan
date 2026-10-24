import simd
import XCTest
@testable import FaceScan

final class FaceBoundsTests: XCTestCase {
    private let maskLow = SIMD3<Float>(-0.075, -0.085, -0.030)
    private let maskHigh = SIMD3<Float>(0.075, 0.055, 0.055)

    func testFullForeheadChinAndBothEarFrontsSurviveBeyondOldMask() throws {
        let bounds = try XCTUnwrap(FaceBounds(vertices: [maskLow, maskHigh]))
        let newlyVisiblePoints: [SIMD3<Float>] = [
            SIMD3(0, 0.120, 0.015),       // Full forehead above the ARKit mask.
            SIMD3(0.060, 0.105, 0.005),   // Side of the forehead.
            SIMD3(0, -0.111, -0.005),     // Below the fitted chin margin.
            SIMD3(-0.099, -0.005, -0.077),
            SIMD3(0.099, -0.005, -0.077) // Both side/ear-front surfaces.
        ]

        for point in newlyVisiblePoints {
            XCTAssertTrue(bounds.contains(point), "New ROI clipped \(point)")
            XCTAssertFalse(legacyBoundsContain(point), "Fixture was already inside the old ROI")
            XCTAssertLessThanOrEqual(simd_length(point), bounds.maximumRadius)
        }
    }

    func testMarginsScaleWithSmallAndLargeFacesWithinAnatomicalCaps() throws {
        let smallLow = SIMD3<Float>(-0.055, -0.075, -0.025)
        let smallHigh = SIMD3<Float>(0.055, 0.055, 0.040)
        let largeLow = SIMD3<Float>(-0.090, -0.105, -0.045)
        let largeHigh = SIMD3<Float>(0.090, 0.105, 0.065)
        let small = try XCTUnwrap(FaceBounds(vertices: [smallLow, smallHigh]))
        let large = try XCTUnwrap(FaceBounds(vertices: [largeLow, largeHigh]))

        XCTAssertEqual(smallLow.x - small.minimum.x, 0.0255, accuracy: 0.000001)
        XCTAssertEqual(small.maximum.y - smallHigh.y, 0.065, accuracy: 0.000001)
        XCTAssertEqual(smallLow.y - small.minimum.y, 0.0255, accuracy: 0.000001)
        XCTAssertEqual(smallLow.z - small.minimum.z, 0.055, accuracy: 0.000001)
        XCTAssertEqual(largeLow.x - large.minimum.x, 0.036, accuracy: 0.000001)
        XCTAssertEqual(large.maximum.y - largeHigh.y, 0.080, accuracy: 0.000001)
        XCTAssertEqual(largeLow.y - large.minimum.y, 0.035, accuracy: 0.000001)
        XCTAssertEqual(largeLow.z - large.minimum.z, 0.070, accuracy: 0.000001)

        XCTAssertTrue(small.contains(SIMD3(0, 0.116, 0)))
        XCTAssertTrue(small.contains(SIMD3(0, -0.097, 0)))
        XCTAssertTrue(small.contains(SIMD3(0.076, 0, -0.072)))
        XCTAssertTrue(large.contains(SIMD3(0, 0.180, 0)))
        XCTAssertTrue(large.contains(SIMD3(0, -0.136, 0)))
        XCTAssertTrue(large.contains(SIMD3(-0.120, 0, -0.103)))
        XCTAssertFalse(small.contains(SIMD3(0.120, 0, 0)))
        XCTAssertFalse(large.contains(SIMD3(0.145, 0, 0)))
    }

    func testRoundedVolumeRejectsShouldersChestAndDistantBackground() throws {
        let bounds = try XCTUnwrap(FaceBounds(vertices: [maskLow, maskHigh]))
        let outsidePoints: [SIMD3<Float>] = [
            SIMD3(0.103, -0.112, 0), // Inside AABB, outside rounded lower corner.
            SIMD3(-0.103, 0.124, 0), // Inside AABB, outside rounded upper corner.
            SIMD3(0.140, -0.160, 0), // Shoulder.
            SIMD3(0, -0.220, -0.030), // Chest.
            SIMD3(0, 0, -0.300),     // Background behind the head.
            SIMD3(0, 0, 0.180),      // Object well in front of the face.
            SIMD3(0, 0.220, 0)
        ]

        for point in outsidePoints {
            XCTAssertFalse(bounds.contains(point), "ROI retained \(point)")
        }
    }

    func testDepthRangeRadiusEnclosesAllAllowedBoundsAtObliquePoses() throws {
        let bounds = try XCTUnwrap(FaceBounds(vertices: [maskLow, maskHigh]))
        for x in [bounds.minimum.x, bounds.maximum.x] {
            for y in [bounds.minimum.y, bounds.maximum.y] {
                for z in [bounds.minimum.z, bounds.maximum.z] {
                    let corner = SIMD3(x, y, z)
                    XCTAssertLessThanOrEqual(simd_length(corner), bounds.maximumRadius + 0.000001)
                    // The projection onto any camera view direction cannot
                    // exceed this radius, including the largest allowed pose.
                    let yaw: Float = 58 * .pi / 180
                    let pitch: Float = 30 * .pi / 180
                    let cameraDirection = SIMD3(sin(yaw) * cos(pitch), sin(pitch),
                                                cos(yaw) * cos(pitch))
                    XCTAssertLessThanOrEqual(abs(simd_dot(corner, cameraDirection)),
                                             bounds.maximumRadius)
                }
            }
        }
        XCTAssertLessThan(bounds.maximumRadius, 0.21)
    }

    func testInvalidOrNonMetricGeometryCannotCreateExpansiveROI() {
        XCTAssertNil(FaceBounds(vertices: []))
        XCTAssertNil(FaceBounds(vertices: [.zero]))
        XCTAssertNil(FaceBounds(vertices: [SIMD3(.nan, 0, 0), maskHigh]))
        XCTAssertNil(FaceBounds(vertices: [maskLow, SIMD3(0, .infinity, 0)]))
        XCTAssertNil(FaceBounds(vertices: [SIMD3(-1, -1, -1), SIMD3(1, 1, 1)]))
        XCTAssertNil(FaceBounds(vertices: [SIMD3(-0.01, -0.01, -0.001),
                                           SIMD3(0.01, 0.01, 0.001)]))
        XCTAssertNil(FaceBounds(vertices: [maskLow + SIMD3(1, 0, 0),
                                           maskHigh + SIMD3(1, 0, 0)]))
    }

    func testNonFiniteSamplesAreRejected() throws {
        let bounds = try XCTUnwrap(FaceBounds(vertices: [maskLow, maskHigh]))
        XCTAssertFalse(bounds.contains(SIMD3(.nan, 0, 0)))
        XCTAssertFalse(bounds.contains(SIMD3(0, .infinity, 0)))
        XCTAssertFalse(bounds.contains(SIMD3(0, 0, -.infinity)))
    }

    func testLongCenterCaptureKeepsOtherViewsReservedForNewGeometry() {
        var budget = ScanFusionBudget()
        for _ in 0..<ScanFusionBudget.maximumVerticesPerAngle {
            XCTAssertTrue(budget.reserveVertex(for: .center))
        }
        for _ in 0..<ScanFusionBudget.maximumTrianglesPerAngle {
            XCTAssertTrue(budget.reserveTriangle(for: .center))
        }
        XCTAssertFalse(budget.reserveVertex(for: .center))
        XCTAssertFalse(budget.reserveTriangle(for: .center))
        for angle in ScanAngle.allCases where angle != .center {
            XCTAssertTrue(budget.reserveVertex(for: angle))
            XCTAssertTrue(budget.reserveTriangle(for: angle))
        }

        budget.reset()
        XCTAssertTrue(budget.reserveVertex(for: .center))
        XCTAssertTrue(budget.reserveTriangle(for: .center))
    }

    func testBudgetUsesNearestViewInCoverageGapsWithoutGrantingCoverage() {
        let gapYaw: Float = 16 * .pi / 180
        XCTAssertNil(ScanCoverageTracker.angle(yaw: gapYaw, pitch: 0))
        XCTAssertEqual(ScanFusionBudget.angle(yaw: gapYaw, pitch: 0), .right)
        XCTAssertEqual(ScanFusionBudget.angle(yaw: -gapYaw, pitch: 0), .left)
        XCTAssertEqual(ScanFusionBudget.angle(yaw: 0, pitch: 20 * .pi / 180), .forehead)
        XCTAssertEqual(ScanFusionBudget.angle(yaw: 0, pitch: -20 * .pi / 180), .chin)
        XCTAssertEqual(ScanFusionBudget.angle(yaw: 45 * .pi / 180, pitch: 0), .farRight)
    }

    private func legacyBoundsContain(_ point: SIMD3<Float>) -> Bool {
        let low = maskLow - SIMD3<Float>(0.014, 0.016, 0.018)
        let high = maskHigh + SIMD3<Float>(0.014, 0.024, 0.020)
        guard point.x >= low.x, point.x <= high.x,
              point.y >= low.y, point.y <= high.y,
              point.z >= low.z, point.z <= high.z else { return false }
        let center = (low + high) * 0.5
        let radius = (high - low) * 0.5
        let x = (point.x - center.x) / radius.x
        let y = (point.y - center.y) / radius.y
        return x * x + y * y <= 1.12
    }
}

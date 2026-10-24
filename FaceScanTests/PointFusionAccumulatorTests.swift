import simd
import XCTest
@testable import FaceScan

final class PointFusionAccumulatorTests: XCTestCase {
    func testEachLaterFrameReplacesHistoricalPositionAndColor() {
        var accumulator = PointFusionAccumulator(position: SIMD3(0.001, 0.02, -0.03),
                                                color: SIMD3(1, 0, 0), frameNumber: 1)

        XCTAssertTrue(accumulator.add(position: SIMD3(0.003, 0.02, -0.03),
                                      color: SIMD3(0, 1, 0), frameNumber: 2))
        assertVector(accumulator.position, SIMD3(0.003, 0.02, -0.03))
        assertVector(accumulator.color, SIMD3(0, 1, 0))
        XCTAssertEqual(accumulator.observedFrames, 2)

        XCTAssertTrue(accumulator.add(position: SIMD3(0.008, 0.02, -0.03),
                                      color: SIMD3(0, 0, 1), frameNumber: 3))
        assertVector(accumulator.position, SIMD3(0.008, 0.02, -0.03))
        assertVector(accumulator.color, SIMD3(0, 0, 1))
        XCTAssertEqual(accumulator.observedFrames, 3)
    }

    func testOneHundredSameFramePixelsReplaceOnlyOnceAndKeepStabilityCount() {
        var accumulator = PointFusionAccumulator(position: SIMD3(repeating: 0),
                                                color: SIMD3(1, 0, 0), frameNumber: 1)

        for _ in 0..<100 {
            XCTAssertTrue(accumulator.add(position: SIMD3(repeating: 0.002),
                                          color: SIMD3(0, 0, 1), frameNumber: 2))
        }

        assertVector(accumulator.position, SIMD3(repeating: 0.002))
        assertVector(accumulator.color, SIMD3(0, 0, 1))
        XCTAssertEqual(accumulator.observedFrames, 2)
    }

    func testSameFrameMeanIncludesOnlyLatestFramePixels() {
        var accumulator = PointFusionAccumulator(position: SIMD3(repeating: 0.001),
                                                color: SIMD3(repeating: 0.1), frameNumber: 10)
        accumulator.add(position: SIMD3(repeating: 0.003),
                        color: SIMD3(repeating: 0.3), frameNumber: 10)
        accumulator.add(position: SIMD3(repeating: 0.006),
                        color: SIMD3(repeating: 0.6), frameNumber: 20)
        accumulator.add(position: SIMD3(repeating: 0.008),
                        color: SIMD3(repeating: 0.8), frameNumber: 20)
        accumulator.add(position: SIMD3(repeating: 0.010),
                        color: SIMD3(repeating: 1), frameNumber: 20)

        // The frame numbered 20 completely replaces frame 10.
        assertVector(accumulator.position, SIMD3(repeating: 0.008))
        assertVector(accumulator.color, SIMD3(repeating: 0.8))
        XCTAssertEqual(accumulator.observedFrames, 2)
    }

    func testHistoricalPixelCountsCannotDiluteLatestFrame() {
        var sparse = PointFusionAccumulator(position: SIMD3(repeating: 0.002),
                                           color: SIMD3(repeating: 0.2), frameNumber: 1)
        var dense = sparse

        for _ in 0..<200 {
            dense.add(position: SIMD3(repeating: 0.002),
                      color: SIMD3(repeating: 0.2), frameNumber: 1)
        }
        sparse.add(position: SIMD3(repeating: 0.008),
                   color: SIMD3(repeating: 0.8), frameNumber: 2)
        for _ in 0..<7 {
            dense.add(position: SIMD3(repeating: 0.008),
                      color: SIMD3(repeating: 0.8), frameNumber: 2)
        }
        sparse.add(position: SIMD3(repeating: 0.005),
                   color: SIMD3(repeating: 0.5), frameNumber: 3)
        for _ in 0..<81 {
            dense.add(position: SIMD3(repeating: 0.005),
                      color: SIMD3(repeating: 0.5), frameNumber: 3)
        }

        assertVector(sparse.position, SIMD3(repeating: 0.005))
        assertVector(dense.position, sparse.position)
        assertVector(dense.color, sparse.color)
        XCTAssertEqual(dense.observedFrames, 3)
    }

    func testPixelOrderDoesNotChangeMeanButNewestFrameOwnsPoint() {
        let batches: [[Float]] = [[0.001, 0.003, 0.002], [0.006], [0.004, 0.008]]
        let forward = fused(batches)
        let reversePixels = fused(batches.map { Array($0.reversed()) })
        let reverseFrameGroups = fused(Array(batches.reversed()))

        assertVector(forward.position, SIMD3(repeating: 0.006))
        assertVector(reversePixels.position, forward.position)
        assertVector(reverseFrameGroups.position, SIMD3(repeating: 0.002))
        assertVector(reversePixels.color, forward.color)
        assertVector(reverseFrameGroups.color, SIMD3(repeating: 0.2))
        XCTAssertEqual(forward.observedFrames, 3)
    }

    func testRepeatedCompletedFramesAreRejectedWithoutChangingState() {
        var accumulator = PointFusionAccumulator(position: SIMD3(0.02, -0.04, 0.01),
                                                color: SIMD3(0.2, 0.4, 0.6), frameNumber: 1)
        accumulator.add(position: SIMD3(0.024, -0.036, 0.014),
                        color: SIMD3(0.4, 0.6, 0.8), frameNumber: 3)
        let before = accumulator

        for frame in [1, 2, 1, -1] {
            XCTAssertFalse(accumulator.add(position: SIMD3(repeating: 0.5),
                                           color: SIMD3(repeating: 1), frameNumber: frame))
        }

        XCTAssertEqual(accumulator.position, before.position)
        XCTAssertEqual(accumulator.color, before.color)
        XCTAssertEqual(accumulator.observedFrames, before.observedFrames)
    }

    func testReplacementPreservesMetricCoordinatesAndRGBChannels() {
        var accumulator = PointFusionAccumulator(position: SIMD3(-0.073, 0.041, -0.012),
                                                color: SIMD3(0.19, 0.38, 0.72), frameNumber: 10)
        accumulator.add(position: SIMD3(-0.071, 0.043, -0.010),
                        color: SIMD3(0.21, 0.42, 0.68), frameNumber: 11)

        assertVector(accumulator.position, SIMD3(-0.071, 0.043, -0.010))
        assertVector(accumulator.color, SIMD3(0.21, 0.42, 0.68))
        XCTAssertLessThan(abs(accumulator.position.x), 0.1)
    }

    func testNonfinitePositionOrColorRejectsEntireSampleAndFrame() {
        var accumulator = PointFusionAccumulator(position: SIMD3(repeating: 0.002),
                                                color: SIMD3(repeating: 0.3), frameNumber: 1)
        let invalid: [Float] = [.nan, .infinity, -.infinity]
        let validPosition = SIMD3<Float>(repeating: 0.004)
        let validColor = SIMD3<Float>(repeating: 0.7)

        for component in 0..<3 {
            for value in invalid {
                var badPosition = validPosition
                badPosition[component] = value
                XCTAssertFalse(accumulator.add(position: badPosition, color: validColor,
                                               frameNumber: 20))
                var badColor = validColor
                badColor[component] = value
                XCTAssertFalse(accumulator.add(position: validPosition, color: badColor,
                                               frameNumber: 20))
            }
        }

        assertVector(accumulator.position, SIMD3(repeating: 0.002))
        assertVector(accumulator.color, SIMD3(repeating: 0.3))
        XCTAssertEqual(accumulator.observedFrames, 1)
        // A rejected future sample must not advance the last accepted frame.
        XCTAssertTrue(accumulator.add(position: validPosition, color: validColor, frameNumber: 2))
        assertVector(accumulator.position, SIMD3(repeating: 0.004))
        XCTAssertEqual(accumulator.observedFrames, 2)
    }

    func testFiniteOutOfRangeColorsAreClampedBeforeFusion() {
        var accumulator = PointFusionAccumulator(position: .zero,
                                                color: SIMD3(-0.5, 0.4, 2), frameNumber: 1)
        assertVector(accumulator.color, SIMD3(0, 0.4, 1))
        accumulator.add(position: .zero, color: SIMD3(2, 0.6, -1), frameNumber: 2)

        assertVector(accumulator.color, SIMD3(1, 0.6, 0))
        XCTAssertEqual(accumulator.observedFrames, 2)
    }

    func testInvalidInitialSampleLeavesEmptyAccumulatorUntilValidObservation() {
        var accumulator = PointFusionAccumulator(position: SIMD3(.nan, 0, 0),
                                                color: SIMD3(repeating: 0.4), frameNumber: 90)
        XCTAssertEqual(accumulator.observedFrames, 0)
        XCTAssertEqual(accumulator.position, .zero)
        XCTAssertEqual(accumulator.color, .zero)

        XCTAssertTrue(accumulator.add(position: SIMD3(0.001, 0.002, -0.003),
                                      color: SIMD3(0.2, 0.4, 0.6), frameNumber: 1))
        assertVector(accumulator.position, SIMD3(0.001, 0.002, -0.003))
        assertVector(accumulator.color, SIMD3(0.2, 0.4, 0.6))
        XCTAssertEqual(accumulator.observedFrames, 1)
    }

    func testNeighborhoodAssociatesOverlappingPointAcrossTwoMillimeterVoxelBoundary() {
        let existing = SIMD3<Float>(0.00195, 0.012, -0.015)
        let newMeasurement = SIMD3<Float>(0.00205, 0.012, -0.015)

        let result = PointFusionNeighborhood.nearestIndex(
            to: newMeasurement, candidateIndices: [7], maximumDistance: 0.00125,
            positionAt: { _ in existing })

        XCTAssertEqual(result, 7)
        var accumulator = PointFusionAccumulator(position: existing,
                                                color: SIMD3(repeating: 0.3), frameNumber: 1)
        accumulator.add(position: newMeasurement, color: SIMD3(repeating: 0.5), frameNumber: 2)
        assertVector(accumulator.position, newMeasurement)
        XCTAssertEqual(accumulator.observedFrames, 2)
    }

    func testNeighborhoodRejectsSeparatedDepthAndInvalidInputs() {
        let measured = SIMD3<Float>(0.002, 0.012, 0.020)
        XCTAssertNil(PointFusionNeighborhood.nearestIndex(
            to: measured, candidateIndices: [0], maximumDistance: 0.00125,
            positionAt: { _ in SIMD3(0.002, 0.012, 0.0214) }))
        XCTAssertNil(PointFusionNeighborhood.nearestIndex(
            to: measured, candidateIndices: [-1, 0], maximumDistance: 0.00125,
            positionAt: { index in
                XCTAssertEqual(index, 0)
                return SIMD3(.nan, 0.012, 0.020)
            }))
        for invalidDistance: Float in [0, -0.001, .nan, .infinity] {
            XCTAssertNil(PointFusionNeighborhood.nearestIndex(
                to: measured, candidateIndices: [0], maximumDistance: invalidDistance,
                positionAt: { _ in XCTFail("Invalid distance must not read candidates"); return measured }))
        }
        XCTAssertNil(PointFusionNeighborhood.nearestIndex(
            to: SIMD3(0, .infinity, 0), candidateIndices: [0], maximumDistance: 0.00125,
            positionAt: { _ in XCTFail("Invalid point must not read candidates"); return measured }))
    }

    func testNeighborhoodChoosesNearestAndBreaksDistanceTiesByStableIndex() {
        let positions: [SIMD3<Float>] = [SIMD3(0.0008, 0, 0), SIMD3(0.0005, 0, 0),
                                         SIMD3(-0.0005, 0, 0), SIMD3(0, 0, 0.001)]
        for order in [[0, 1, 2, 3], [3, 2, 1, 0], [2, 0, 3, 1, 1]] {
            XCTAssertEqual(PointFusionNeighborhood.nearestIndex(
                to: .zero, candidateIndices: order, maximumDistance: 0.00125,
                positionAt: { positions[$0] }), 1)
        }
        XCTAssertEqual(PointFusionNeighborhood.nearestIndex(
            to: .zero, candidateIndices: [0, 3], maximumDistance: 0.00125,
            positionAt: { positions[$0] }), 0)
        XCTAssertNil(PointFusionNeighborhood.nearestIndex(
            to: .zero, candidateIndices: [], maximumDistance: 0.00125,
            positionAt: { _ in XCTFail("No candidates must not read positions"); return .zero }))
    }

    private func fused(_ batches: [[Float]]) -> PointFusionAccumulator {
        var accumulator = PointFusionAccumulator(position: SIMD3(repeating: batches[0][0]),
                                                color: SIMD3(repeating: batches[0][0] * 100),
                                                frameNumber: 0)
        for (frame, batch) in batches.enumerated() {
            for (index, value) in batch.enumerated() where frame != 0 || index != 0 {
                accumulator.add(position: SIMD3(repeating: value),
                                color: SIMD3(repeating: value * 100), frameNumber: frame)
            }
        }
        return accumulator
    }

    private func assertVector(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>,
                              accuracy: Float = 0.0000001,
                              file: StaticString = #filePath, line: UInt = #line) {
        for component in 0..<3 {
            XCTAssertEqual(actual[component], expected[component], accuracy: accuracy,
                           file: file, line: line)
        }
    }
}

import simd
import XCTest
@testable import FaceScan

final class PointFusionSpatialIndexTests: XCTestCase {
    func testMovedPointRemainsDiscoverableAcrossOriginalVoxelBoundary() {
        var index = PointFusionSpatialIndex()
        index.update(index: 7, position: SIMD3(0.0019, 0, 0))
        index.update(index: 7, position: SIMD3(0.0025, 0, 0))
        index.update(index: 7, position: SIMD3(0.0029, 0, 0))

        XCTAssertEqual(index.indices(inSameCellAs: SIMD3(0.0019, 0, 0)), [])
        XCTAssertEqual(index.indices(inSameCellAs: SIMD3(0.0029, 0, 0)), [7])
        XCTAssertEqual(index.indices(inNeighborhoodOf: SIMD3(0.00405, 0, 0)), [7])
        // The newest position is only 1.15 mm from this later measurement.
        XCTAssertEqual(PointFusionNeighborhood.nearestIndex(
            to: SIMD3(0.00405, 0, 0),
            candidateIndices: index.indices(inNeighborhoodOf: SIMD3(0.00405, 0, 0)),
            maximumDistance: 0.00125, positionAt: { _ in SIMD3(0.0029, 0, 0) }), 7)
    }

    func testLatestFrameReplacementMovesIndexedPointWithoutLeavingHistoricalCopy() {
        var index = PointFusionSpatialIndex()
        var point = PointFusionAccumulator(position: SIMD3(0.0019, 0, 0),
                                           color: SIMD3(1, 0, 0), frameNumber: 1)
        index.update(index: 4, position: point.position)
        let updated = SIMD3<Float>(0.0026, 0, 0)
        let associated = PointFusionNeighborhood.nearestIndex(
            to: updated, candidateIndices: index.indices(inNeighborhoodOf: updated),
            maximumDistance: 0.00125, positionAt: { _ in point.position })
        XCTAssertEqual(associated, 4)

        XCTAssertTrue(point.add(position: updated, color: SIMD3(0, 0, 1), frameNumber: 2))
        index.update(index: 4, position: point.position)

        XCTAssertEqual(point.position, updated)
        XCTAssertTrue(index.indices(inSameCellAs: SIMD3(0.0019, 0, 0)).isEmpty)
        XCTAssertEqual(index.indices(inSameCellAs: updated), [4])
        XCTAssertEqual(index.indices(inNeighborhoodOf: updated), [4])
        XCTAssertEqual(point.observedFrames, 2)

        // A stale frame cannot roll the point or its cell back to old geometry.
        XCTAssertFalse(point.add(position: SIMD3(0.0019, 0, 0),
                                 color: SIMD3(1, 0, 0), frameNumber: 1))
        index.update(index: 4, position: point.position)
        XCTAssertTrue(index.indices(inSameCellAs: SIMD3(0.0019, 0, 0)).isEmpty)
        XCTAssertEqual(index.indices(inSameCellAs: updated), [4])
    }

    func testMovingIntoOccupiedCellKeepsBothStablePointIndices() {
        var index = PointFusionSpatialIndex()
        index.update(index: 2, position: SIMD3(0.0019, 0, 0))
        index.update(index: 9, position: SIMD3(0.0024, 0, 0))

        index.update(index: 2, position: SIMD3(0.0025, 0, 0))

        XCTAssertEqual(Set(index.indices(inSameCellAs: SIMD3(0.0026, 0, 0))), Set([2, 9]))
        XCTAssertEqual(index.indices(inSameCellAs: SIMD3(0.0026, 0, 0)).count, 2)
        XCTAssertTrue(index.indices(inSameCellAs: SIMD3(0.0019, 0, 0)).isEmpty)
        XCTAssertEqual(Set(index.indices(inNeighborhoodOf: SIMD3(0.0026, 0, 0))), Set([2, 9]))
    }

    func testRepeatedMovesAndRepeatedSameCellUpdatesNeverDuplicatePoint() {
        var index = PointFusionSpatialIndex()
        let positions: [SIMD3<Float>] = [SIMD3(0.0019, 0, 0), SIMD3(0.0025, 0, 0),
                                         SIMD3(-0.0001, 0, 0), SIMD3(-0.0021, 0, 0),
                                         SIMD3(0.0045, 0, 0)]
        for _ in 0..<50 {
            for position in positions {
                index.update(index: 5, position: position)
                index.update(index: 5, position: position)
                XCTAssertEqual(index.indices(inSameCellAs: position), [5])
                XCTAssertEqual(index.indices(inNeighborhoodOf: position), [5])
                // All fixture positions are in distinct cells. Exactly one
                // should contain the point, with no stale copy left behind.
                XCTAssertEqual(positions.reduce(0) {
                    $0 + index.indices(inSameCellAs: $1).count
                }, 1)
            }
        }
    }

    func testResetRemovesAllCellAndReverseMappingsAndAllowsReuse() {
        var index = PointFusionSpatialIndex()
        index.update(index: 0, position: .zero)
        index.update(index: 1, position: SIMD3(-0.0025, 0.0025, -0.0025))
        index.reset()

        XCTAssertTrue(index.indices(inSameCellAs: .zero).isEmpty)
        XCTAssertTrue(index.indices(inNeighborhoodOf: .zero).isEmpty)
        index.update(index: 1, position: SIMD3(0.0001, 0.0001, 0.0001))
        XCTAssertEqual(index.indices(inNeighborhoodOf: .zero), [1])
    }

    func testPositiveAndNegativeCoordinatesUseFloorCellsInThreeDimensions() {
        var index = PointFusionSpatialIndex()
        let negative = SIMD3<Float>(-0.0001, -0.0001, -0.0001)
        let positive = SIMD3<Float>(0.0001, 0.0001, 0.0001)
        let separatedDepth = SIMD3<Float>(0.0001, 0.0001, 0.0041)
        index.update(index: 3, position: negative)
        index.update(index: 4, position: positive)
        index.update(index: 5, position: separatedDepth)

        XCTAssertEqual(index.indices(inSameCellAs: negative), [3])
        XCTAssertEqual(index.indices(inSameCellAs: positive), [4])
        XCTAssertEqual(Set(index.indices(inNeighborhoodOf: .zero)), Set([3, 4]))
        index.update(index: 3, position: SIMD3(0.0021, 0.0021, 0.0021))
        XCTAssertTrue(index.indices(inSameCellAs: negative).isEmpty)
        XCTAssertEqual(Set(index.indices(inNeighborhoodOf: .zero)), Set([3, 4]))
    }

    func testInvalidUpdatesAndQueriesLeaveAcceptedLocationIntact() {
        var index = PointFusionSpatialIndex()
        let accepted = SIMD3<Float>(0.001, 0.001, 0.001)
        index.update(index: 8, position: accepted)
        index.update(index: -1, position: accepted)
        let invalidPositions: [SIMD3<Float>] = [SIMD3(.nan, 0, 0), SIMD3(0, .infinity, 0),
                                                SIMD3(0, 0, -.infinity),
                                                SIMD3(repeating: .greatestFiniteMagnitude)]
        for position in invalidPositions {
            index.update(index: 8, position: position)
            index.update(index: 9, position: position)
            XCTAssertEqual(index.indices(inSameCellAs: accepted), [8])
            XCTAssertTrue(index.indices(inSameCellAs: position).isEmpty)
            XCTAssertTrue(index.indices(inNeighborhoodOf: position).isEmpty)
        }
        XCTAssertEqual(index.indices(inNeighborhoodOf: accepted), [8])
    }

    func testCustomVoxelSizeChangesQueryNeighborhoodWithoutChangingIndices() {
        var index = PointFusionSpatialIndex(voxelSize: 0.01)
        index.update(index: 31, position: SIMD3(0.004, 0, 0))
        index.update(index: 42, position: SIMD3(0.009, 0, 0))

        XCTAssertEqual(Set(index.indices(inSameCellAs: SIMD3(0.001, 0, 0))), Set([31, 42]))
        XCTAssertEqual(Set(index.indices(inNeighborhoodOf: SIMD3(0.015, 0, 0))), Set([31, 42]))
    }
}

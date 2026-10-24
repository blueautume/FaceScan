import simd
import XCTest
@testable import FaceScan

final class LivePointCloudTests: XCTestCase {
    func testUniformSamplingSpansFullStableIndexRange() throws {
        let vertices = fixture(count: 101)

        let snapshot = try XCTUnwrap(sample(vertices, maximumPoints: 6))

        XCTAssertEqual(snapshot.vertices.map(\.position.x), [0, 0.02, 0.04, 0.06, 0.08, 0.1])
        XCTAssertEqual(snapshot.pointCount, 6)
        XCTAssertEqual(snapshot.confirmedPointCount, 101)
    }

    func testPointsFromLaterSideViewRemainVisibleAfterCapIsReached() throws {
        let front = fixture(count: 100)
        let withLaterSide = fixture(count: 140)

        let earlier = try XCTUnwrap(sample(front, maximumPoints: 10))
        let later = try XCTUnwrap(sample(withLaterSide, maximumPoints: 10))

        XCTAssertEqual(earlier.pointCount, 10)
        XCTAssertEqual(later.pointCount, 10)
        XCTAssertEqual(later.vertices.last?.position, withLaterSide.last?.position)
        XCTAssertTrue(later.vertices.contains { $0.position.x > front.last!.position.x })
    }

    func testUncappedPointsRetainOrderColorsAndMeterCoordinates() throws {
        let vertices = [
            ScanVertex(position: SIMD3(-0.073, 0.041, -0.012), color: SIMD3(0.19, 0.38, 0.72)),
            ScanVertex(position: SIMD3(0.084, -0.062, 0.028), color: SIMD3(0.85, 0.65, 0.43))
        ]

        let snapshot = try XCTUnwrap(sample(vertices, maximumPoints: 10, revision: 37))

        XCTAssertEqual(snapshot.vertices.map(\.position), vertices.map(\.position))
        XCTAssertEqual(snapshot.vertices.map(\.color), vertices.map(\.color))
        XCTAssertEqual(snapshot.revision, 37)
        XCTAssertEqual(snapshot.confirmedPointCount, 2)
        XCTAssertFalse(snapshot.isSample)
    }

    func testSingleFramePointsAreExcludedBeforeSamplingAndCounting() throws {
        let vertices = fixture(count: 7)
        let observations = [1, 2, 1, 8, 0, 2, 1]

        let snapshot = try XCTUnwrap(sample(vertices, observations: observations,
                                            maximumPoints: 2))

        XCTAssertEqual(snapshot.vertices.map(\.position), [vertices[1].position, vertices[5].position])
        XCTAssertEqual(snapshot.confirmedPointCount, 3)
    }

    func testSnapshotIsNilForEmptyOrUnconfirmedInput() {
        XCTAssertNil(sample([]))
        XCTAssertNil(sample(fixture(count: 3), observations: [1, 1, 0]))
        XCTAssertNil(sample(fixture(count: 3), revision: 1))
        XCTAssertNil(DepthReconstructor().makePointCloudSnapshot())
    }

    func testNonPositiveLimitIsRejectedWithoutReadingSource() {
        for limit in [0, -1] {
            let result = LivePointCloudSampler.makeSnapshot(
                sourceCount: 3, revision: 4, maximumPoints: limit,
                observedFramesAt: { _ in XCTFail("Source must not be read for invalid limit"); return 2 },
                vertexAt: { _ in XCTFail("Source must not be copied for invalid limit"); return self.fixture(count: 1)[0] })
            XCTAssertNil(result)
        }
    }

    func testOnlyBoundedNumberOfVerticesAreMaterialized() throws {
        var copiedIndices: [Int] = []

        let snapshot = try XCTUnwrap(LivePointCloudSampler.makeSnapshot(
            sourceCount: 180_000, revision: 80, maximumPoints: 24_000,
            observedFramesAt: { _ in 2 },
            vertexAt: { index in
                copiedIndices.append(index)
                return ScanVertex(position: SIMD3(Float(index), 0, 0), color: SIMD3(repeating: 0.5))
            }))

        XCTAssertEqual(snapshot.pointCount, 24_000)
        XCTAssertEqual(snapshot.confirmedPointCount, 180_000)
        XCTAssertEqual(copiedIndices.count, 24_000)
        XCTAssertEqual(Set(copiedIndices).count, 24_000)
        XCTAssertEqual(copiedIndices.first, 0)
        XCTAssertEqual(copiedIndices.last, 179_999)
        XCTAssertTrue(zip(copiedIndices, copiedIndices.dropFirst()).allSatisfy { $0.0 < $0.1 })
    }

    func testRepeatedSamplingIsDeterministicAndSinglePointLimitWorks() throws {
        let vertices = fixture(count: 17)
        let first = try XCTUnwrap(sample(vertices, maximumPoints: 5))
        let repeated = try XCTUnwrap(sample(vertices, maximumPoints: 5))
        let single = try XCTUnwrap(sample(vertices, maximumPoints: 1))

        XCTAssertEqual(first.vertices.map(\.position), repeated.vertices.map(\.position))
        XCTAssertEqual(single.pointCount, 1)
        XCTAssertEqual(single.vertices[0].position, vertices[8].position)
        XCTAssertEqual(single.confirmedPointCount, 17)
    }

    private func sample(_ vertices: [ScanVertex], observations: [Int]? = nil,
                        maximumPoints: Int = 24_000,
                        revision: Int = 5) -> LivePointCloudSnapshot? {
        LivePointCloudSampler.makeSnapshot(
            sourceCount: vertices.count, revision: revision, maximumPoints: maximumPoints,
            observedFramesAt: { observations?[$0] ?? 2 }, vertexAt: { vertices[$0] })
    }

    private func fixture(count: Int) -> [ScanVertex] {
        (0..<count).map { index in
            ScanVertex(position: SIMD3(Float(index) / 1000, -0.02, 0.03),
                       color: SIMD3(Float(index % 255) / 255, 0.5, 0.8))
        }
    }
}

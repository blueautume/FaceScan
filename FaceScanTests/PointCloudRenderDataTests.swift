import SceneKit
import XCTest
import simd
@testable import FaceScan

final class PointCloudRenderDataTests: XCTestCase {
    func testPreparationPacksMeasuredCoordinatesAndColorsInSourceOrder() throws {
        let vertices = fixture()
        let invalidPosition = ScanVertex(position: SIMD3(.nan, 0, 0), color: SIMD3(repeating: 0.5))
        let invalidColor = ScanVertex(position: .zero, color: SIMD3(1.1, 0, 0))
        let data = PointCloudRenderDataBuilder().prepare(vertices: [invalidPosition, vertices[0], invalidColor] + Array(vertices.dropFirst()))
        XCTAssertEqual(data.pointCount, 3)
        XCTAssertEqual(data.vertexData.count, 3 * 24)
        XCTAssertEqual(integers(data.pointIndexData), [0, 1, 2])
        for (index, vertex) in vertices.enumerated() {
            XCTAssertEqual(vector(data.vertexData, offset: index * 24), vertex.position)
            XCTAssertEqual(vector(data.vertexData, offset: index * 24 + 12), vertex.color)
        }
        let center = try XCTUnwrap(data.center)
        XCTAssertEqual(center.x, 0, accuracy: 1e-7)
        XCTAssertEqual(center.y, 0.005, accuracy: 1e-7)
        XCTAssertEqual(center.z, 0, accuracy: 1e-7)
        XCTAssertTrue(data.surfaceIndexData.isEmpty)
        XCTAssertNil(data.birthData)
        XCTAssertNil(data.animationEndTime)
    }

    func testSurfaceRemapsInvalidVerticesAndRejectsUnmeasuredOrDegenerateFaces() {
        let invalid = ScanVertex(position: SIMD3(.infinity, 0, 0), color: SIMD3(repeating: 0.5))
        let vertices = [invalid] + fixture()
        let triangles: [UInt32] = [1, 2, 3, 0, 2, 3, 1, 1, 2, 1, 2, 99, 1, 2]
        let data = PointCloudRenderDataBuilder().prepare(vertices: vertices, triangleIndices: triangles)
        XCTAssertEqual(integers(data.surfaceIndexData), [0, 1, 2])
        XCTAssertEqual(data.pointCount, 3)
        let line = (0..<3).map {
            ScanVertex(position: SIMD3(Float($0) * 0.02, 0, 0), color: SIMD3(repeating: 0.5))
        }
        let degenerate = PointCloudRenderDataBuilder().prepare(vertices: line, triangleIndices: [0, 1, 2])
        XCTAssertTrue(degenerate.surfaceIndexData.isEmpty)
    }

    func testImmutablePayloadSurvivesWorkspaceReuseAtTheSamePointCount() {
        let builder = PointCloudRenderDataBuilder()
        let first = builder.prepare(vertices: fixture(), triangleIndices: [0, 1, 2])
        let originalBytes = first.vertexData
        let changed = fixture().map {
            ScanVertex(position: $0.position + SIMD3(0.1, 0, 0.02), color: $0.color)
        }
        let second = builder.prepare(vertices: changed)
        XCTAssertEqual(first.vertexData, originalBytes)
        XCTAssertNotEqual(second.vertexData, first.vertexData)
        XCTAssertEqual(second.pointIndexData, first.pointIndexData)
        XCTAssertTrue(second.surfaceIndexData.isEmpty)
        XCTAssertEqual(integers(first.surfaceIndexData), [0, 1, 2])
    }

    func testStableFusionIDsRetainBirthsWhileNearbyDistinctParticlesRemainIndependent() throws {
        let builder = PointCloudRenderDataBuilder()
        let start = PointCloudAnimationTime.origin + 10
        let original = fixture()[0]
        let first = builder.prepare(vertices: [original], pointIDs: [42], animates: true, time: start)
        let firstBirth = try birth(first, index: 0)
        let moved = ScanVertex(position: original.position + SIMD3(0.012, 0.002, -0.003), color: original.color)
        let movedData = builder.prepare(vertices: [moved], pointIDs: [42], animates: true, time: start + 0.2)
        XCTAssertEqual(try birth(movedData, index: 0), firstBirth)
        XCTAssertEqual(try seed(movedData, index: 0), try seed(first, index: 0))
        XCTAssertEqual(movedData.animationEndTime, first.animationEndTime)
        XCTAssertEqual(vector(movedData.vertexData, offset: 0), moved.position)

        let nearbyNew = ScanVertex(position: moved.position + SIMD3(0.0002, 0, 0), color: original.color)
        let later = builder.prepare(vertices: [moved, nearbyNew], pointIDs: [42, 43],
                                    animates: true, time: start + 0.4)
        XCTAssertEqual(try birth(later, index: 0), firstBirth)
        let newBirth = try birth(later, index: 1)
        XCTAssertGreaterThanOrEqual(newBirth, PointCloudAnimationTime.shaderTime(at: start + 0.4))
        XCTAssertNotEqual(newBirth, firstBirth, "A new source point must not reuse a nearby particle's old flight.")
        let repeated = builder.prepare(vertices: [nearbyNew], pointIDs: [43], animates: true, time: start + 2)
        XCTAssertEqual(try birth(repeated, index: 0), newBirth)
        XCTAssertEqual(repeated.animationEndTime, later.animationEndTime)
    }

    func testFixtureFallbackUsesPrecisePositionsWithoutFourMillimeterReuse() throws {
        let builder = PointCloudRenderDataBuilder()
        let start = PointCloudAnimationTime.origin + 1
        let original = fixture()[0]
        let first = builder.prepare(vertices: [original], animates: true, time: start)
        let nearby = ScanVertex(position: original.position + SIMD3(0.0002, 0, 0), color: original.color)
        let next = builder.prepare(vertices: [nearby, original], animates: true, time: start + 0.3)
        XCTAssertNotEqual(try birth(next, index: 0), try birth(first, index: 0))
        XCTAssertEqual(try birth(next, index: 1), try birth(first, index: 0))
        XCTAssertEqual(try seed(next, index: 1), try seed(first, index: 0))
        let independent = PointCloudRenderDataBuilder().prepare(vertices: [original], animates: true, time: start)
        XCTAssertEqual(first.birthData, independent.birthData, "Fixture seeds must be stable across builders.")
    }

    func testSeededBirthsSpreadUniformlyAndOnlyAgeAfterThePresentationACK() throws {
        let count = 2_048
        let vertices = (0..<count).map { _ in fixture()[0] }
        let ids = (0..<count).map(UInt64.init)
        let builder = PointCloudRenderDataBuilder()
        let preparedAt = PointCloudAnimationTime.origin + 10
        let presentedAt = preparedAt + 4
        builder.beginPreparation()
        let prepared = builder.prepare(vertices: vertices, pointIDs: ids, animates: true, time: preparedAt)
        XCTAssertEqual(prepared.preparationTime, preparedAt)
        var buckets = [Int](repeating: 0, count: 10)
        var seeds: Set<Float> = []
        var latestOffset = 0.0
        for index in 0..<count {
            let value = try seed(prepared, index: index)
            let encoded = try birth(prepared, index: index)
            XCTAssertTrue((0...1).contains(value))
            XCTAssertLessThan(encoded, 0)
            let delay = Double(-encoded - 1)
            XCTAssertEqual(delay, Double(value) * PointCloudParticleStyle.revealSpread, accuracy: 0.0000001)
            XCTAssertTrue((0...PointCloudParticleStyle.revealSpread + 0.0000001).contains(delay))
            let duration = PointCloudParticleStyle.duration(seed: value)
            XCTAssertTrue((0.58...0.76).contains(duration))
            buckets[min(9, Int(value * 10))] += 1
            seeds.insert(value)
            latestOffset = max(latestOffset, delay + duration)
        }
        XCTAssertGreaterThan(seeds.count, 2_000)
        XCTAssertTrue(buckets.allSatisfy { $0 >= 140 }, "Births should cover the whole reveal interval.")
        XCTAssertEqual(try XCTUnwrap(prepared.animationEndTime(presentedAt: presentedAt)),
                       presentedAt + latestOffset, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(prepared.animationEndTime(presentedAt: presentedAt))
                       - XCTUnwrap(prepared.animationEndTime), 4, accuracy: 0.000001)

        builder.finishPreparation(accepted: true, presentedAt: presentedAt)
        let committed = builder.prepare(vertices: vertices, pointIDs: ids, animates: true, time: presentedAt + 0.01)
        for index in 0..<count {
            let expected = PointCloudAnimationTime.shaderTime(at: presentedAt) - (try birth(prepared, index: index)) - 1
            XCTAssertEqual(try birth(committed, index: index), expected, accuracy: 0.000002)
            XCTAssertGreaterThanOrEqual(try birth(committed, index: index), 0)
            XCTAssertEqual(try seed(committed, index: index), try seed(prepared, index: index))
        }
        XCTAssertNil(committed.latestPendingBirthEndOffset)
        XCTAssertEqual(committed.animationEndTime(presentedAt: presentedAt + 20), committed.animationEndTime,
                       "Merely displaying an existing batch later must not extend old flights.")
    }

    func testFutureStartsFromThePreviousBatchAreNotShiftedAgain() throws {
        let vertices = fixture()
        let builder = PointCloudRenderDataBuilder()
        let start = PointCloudAnimationTime.origin + 10
        builder.beginPreparation()
        let first = builder.prepare(vertices: vertices, pointIDs: [1, 2, 3], animates: true, time: start)
        builder.finishPreparation(accepted: true, presentedAt: start + 1)
        let previous = builder.prepare(vertices: vertices, pointIDs: [1, 2, 3], animates: true, time: start + 1.001)
        XCTAssertTrue(try (0..<3).contains { try birth(previous, index: $0) > PointCloudAnimationTime.shaderTime(at: start + 1.001) })

        builder.beginPreparation()
        let mixed = builder.prepare(vertices: vertices + [vertices[0]], pointIDs: [1, 2, 3, 4],
                                    animates: true, time: start + 1.002)
        for index in 0..<3 { XCTAssertEqual(try birth(mixed, index: index), try birth(previous, index: index)) }
        XCTAssertLessThan(try birth(mixed, index: 3), 0)
        builder.finishPreparation(accepted: true, presentedAt: start + 1.03)
        let committed = builder.prepare(vertices: vertices + [vertices[0]], pointIDs: [1, 2, 3, 4],
                                        animates: true, time: start + 1.04)
        for index in 0..<3 { XCTAssertEqual(try birth(committed, index: index), try birth(previous, index: index)) }
        XCTAssertGreaterThan(try birth(committed, index: 3), PointCloudAnimationTime.shaderTime(at: start + 1.03))
        XCTAssertEqual(try seed(first, index: 0), try seed(committed, index: 0))
    }

    func testInvalidVerticesKeepTheirOriginalIDAlignmentAndInvalidIDCountFallsBackSafely() {
        let start = PointCloudAnimationTime.origin + 1
        let valid = fixture()
        let invalid = ScanVertex(position: SIMD3(.nan, 0, 0), color: SIMD3(repeating: 0.5))
        let packed = PointCloudRenderDataBuilder().prepare(vertices: [invalid] + valid,
                                                           pointIDs: [99, 10, 20, 30], animates: true, time: start)
        let expected = PointCloudRenderDataBuilder().prepare(vertices: valid, pointIDs: [10, 20, 30],
                                                             animates: true, time: start)
        XCTAssertEqual(packed.birthData, expected.birthData)
        XCTAssertEqual(packed.vertexData, expected.vertexData)
        let badIDs = PointCloudRenderDataBuilder().prepare(vertices: valid, pointIDs: [10], animates: true, time: start)
        let fallback = PointCloudRenderDataBuilder().prepare(vertices: valid, animates: true, time: start)
        XCTAssertEqual(badIDs.birthData, fallback.birthData)
    }

    func testResetAndEmptyInputClearBirthHistory() throws {
        let builder = PointCloudRenderDataBuilder()
        let start = PointCloudAnimationTime.origin + 1
        let first = builder.prepare(vertices: fixture(), animates: true, time: start)
        builder.reset()
        let restarted = builder.prepare(vertices: fixture(), animates: true, time: start + 1)
        XCTAssertEqual(try birth(restarted, index: 0) - birth(first, index: 0), 1, accuracy: 0.000001)
        let empty = builder.prepare(vertices: [], animates: true, time: start + 2)
        XCTAssertEqual(empty.pointCount, 0)
        XCTAssertNil(empty.center)
        XCTAssertNil(empty.birthData)
        XCTAssertNil(empty.animationEndTime)
        XCTAssertTrue(empty.vertexData.isEmpty)
        let afterEmpty = builder.prepare(vertices: fixture(), animates: true, time: start + 3)
        XCTAssertEqual(try birth(afterEmpty, index: 0) - birth(first, index: 0), 3, accuracy: 0.000001)
    }

    func testSupersededOrUnpresentedPreparationDoesNotAgeUnseenParticlesOrClearVisibleHistory() throws {
        let builder = PointCloudRenderDataBuilder()
        let vertices = fixture()
        let start = PointCloudAnimationTime.origin + 10
        builder.beginPreparation()
        _ = builder.prepare(vertices: [vertices[0]], pointIDs: [1], animates: true, time: start)
        builder.finishPreparation(accepted: true, presentedAt: start + 1)
        let visible = builder.prepare(vertices: [vertices[0]], pointIDs: [1], animates: true, time: start + 1)
        builder.beginPreparation()
        _ = builder.prepare(vertices: vertices, pointIDs: [1, 2, 3], animates: true, time: start + 2)
        builder.finishPreparation(accepted: false)
        builder.beginPreparation()
        let latest = builder.prepare(vertices: vertices, pointIDs: [1, 2, 3], animates: true, time: start + 3)
        XCTAssertEqual(try birth(latest, index: 0), try birth(visible, index: 0))
        XCTAssertLessThan(try birth(latest, index: 1), 0, "An unseen point still needs a full presentation-relative flight.")
        builder.finishPreparation(accepted: true, presentedAt: nil)
        builder.beginPreparation()
        let afterInvisible = builder.prepare(vertices: vertices, pointIDs: [1, 2, 3], animates: true, time: start + 4)
        XCTAssertLessThan(try birth(afterInvisible, index: 1), 0)
        builder.finishPreparation(accepted: true, presentedAt: start + 4.1)
        let committed = builder.prepare(vertices: vertices, pointIDs: [1, 2, 3], animates: true, time: start + 4.2)
        builder.beginPreparation()
        _ = builder.prepare(vertices: [], animates: true, time: start + 5)
        builder.finishPreparation(accepted: false)
        let afterEmpty = builder.prepare(vertices: vertices, pointIDs: [1, 2, 3], animates: true, time: start + 6)
        XCTAssertEqual(afterEmpty.birthData, committed.birthData)
        XCTAssertEqual(afterEmpty.animationEndTime, committed.animationEndTime)
        builder.reset()
        builder.beginPreparation()
        let reset = builder.prepare(vertices: vertices, pointIDs: [1, 2, 3], animates: true, time: start + 7)
        XCTAssertLessThan(try birth(reset, index: 0), 0)
        builder.finishPreparation(accepted: false)
    }

    @MainActor
    func testDisplayModesShareVertexSourcesAndReuseMaterialsAndPointElements() throws {
        let builder = PointCloudRenderDataBuilder()
        let resources = PointCloudRenderResources()
        let data = builder.prepare(vertices: fixture(), triangleIndices: [0, 1, 2])
        let first = resources.make(data: data)
        let points = try XCTUnwrap(first.points)
        let surface = try XCTUnwrap(first.surface)
        XCTAssertEqual(points.elements.first?.primitiveType, .point)
        XCTAssertEqual(surface.elements.first?.primitiveType, .triangles)
        XCTAssertTrue(points.sources(for: .vertex).first === surface.sources(for: .vertex).first)
        XCTAssertTrue(points.sources(for: .color).first === surface.sources(for: .color).first)
        XCTAssertTrue(points.firstMaterial === surface.firstMaterial)
        XCTAssertEqual(points.firstMaterial?.lightingModel, .constant)
        XCTAssertTrue(points.firstMaterial?.isDoubleSided == true)
        let element = try XCTUnwrap(points.elements.first)
        XCTAssertEqual(element.pointSize, 0.0014, accuracy: 1e-8)
        XCTAssertEqual(element.minimumPointScreenSpaceRadius, 1.4, accuracy: 1e-6)
        XCTAssertEqual(element.maximumPointScreenSpaceRadius, 2, accuracy: 1e-6)
        let next = resources.make(data: builder.prepare(vertices: fixture()))
        XCTAssertTrue(next.points?.elements.first === points.elements.first)
        XCTAssertTrue(next.points?.firstMaterial === points.firstMaterial)
        XCTAssertTrue(next.points === next.surface, "A scan without measured triangles keeps its colored points.")
    }

    @MainActor
    func testFlightUsesASeparateReusableShaderMaterial() throws {
        let builder = PointCloudRenderDataBuilder()
        let resources = PointCloudRenderResources()
        let first = resources.make(data: builder.prepare(vertices: fixture(), animates: true,
                                                         time: PointCloudAnimationTime.origin + 1))
        let material = try XCTUnwrap(first.points?.firstMaterial)
        XCTAssertEqual(material.shaderModifiers?[.geometry], PointCloudFlight.shader)
        XCTAssertEqual(first.points?.sources(for: .texcoord).first?.dataStride, 8)
        let second = resources.make(data: builder.prepare(vertices: fixture(), animates: true,
                                                          time: PointCloudAnimationTime.origin + 2))
        XCTAssertTrue(second.points?.firstMaterial === material)
        let settled = resources.make(data: builder.prepare(vertices: fixture()))
        XCTAssertFalse(settled.points?.firstMaterial === material)
        XCTAssertNil(settled.points?.firstMaterial?.shaderModifiers?[.geometry])
        XCTAssertNil(settled.points?.sources(for: .texcoord).first)
    }

    @MainActor
    func testAnimatedCullingBoundsExpandWithoutChangingMeasuredPayloadOrCenter() throws {
        let builder = PointCloudRenderDataBuilder()
        let measured = builder.prepare(vertices: fixture())
        let animated = builder.prepare(vertices: fixture(), animates: true,
                                        time: PointCloudAnimationTime.origin + 1)
        let resources = PointCloudRenderResources()
        let points = try XCTUnwrap(resources.make(data: animated).points)
        let plain = try XCTUnwrap(resources.make(data: measured).points)

        XCTAssertEqual(animated.vertexData, measured.vertexData)
        XCTAssertEqual(animated.center, measured.center)
        XCTAssertEqual(points.boundingBox.min.x, plain.boundingBox.min.x - 0.025, accuracy: 0.000001)
        XCTAssertEqual(points.boundingBox.min.y, plain.boundingBox.min.y - 0.025, accuracy: 0.000001)
        XCTAssertEqual(points.boundingBox.min.z, plain.boundingBox.min.z - 0.025, accuracy: 0.000001)
        XCTAssertEqual(points.boundingBox.max.x, plain.boundingBox.max.x + 0.025, accuracy: 0.000001)
        XCTAssertEqual(points.boundingBox.max.y, plain.boundingBox.max.y + 0.025, accuracy: 0.000001)
        XCTAssertEqual(points.boundingBox.max.z, plain.boundingBox.max.z + 0.025, accuracy: 0.000001)
    }

    private func fixture() -> [ScanVertex] {
        [ScanVertex(position: SIMD3(-0.04, 0.05, 0), color: SIMD3(0.9, 0.3, 0.1)),
         ScanVertex(position: SIMD3(0.04, 0.05, 0), color: SIMD3(0.2, 0.8, 0.3)),
         ScanVertex(position: SIMD3(0, -0.04, 0), color: SIMD3(0.2, 0.4, 0.9))]
    }

    private func integers(_ data: Data) -> [UInt32] {
        data.withUnsafeBytes { bytes in
            (0..<(data.count / 4)).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
        }
    }

    private func vector(_ data: Data, offset: Int) -> SIMD3<Float> {
        data.withUnsafeBytes {
            SIMD3($0.loadUnaligned(fromByteOffset: offset, as: Float.self),
                  $0.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                  $0.loadUnaligned(fromByteOffset: offset + 8, as: Float.self))
        }
    }

    private func seed(_ data: PointCloudRenderData, index: Int) throws -> Float {
        try XCTUnwrap(data.birthData).withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: index * 8 + 4, as: Float.self)
        }
    }

    private func birth(_ data: PointCloudRenderData, index: Int) throws -> Float {
        try XCTUnwrap(data.birthData).withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: index * 8, as: Float.self)
        }
    }
}

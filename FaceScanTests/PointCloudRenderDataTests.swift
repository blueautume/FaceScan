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

    func testBirthHistoryFollowsNearbyPointsAndOnlyNewPointsExtendDeadline() throws {
        let builder = PointCloudRenderDataBuilder()
        let start = PointCloudAnimationTime.origin + 10
        let vertices = fixture()
        let first = builder.prepare(vertices: [vertices[0]], animates: true, time: start)
        let firstBirth = try birth(first, index: 0)
        let nearby = ScanVertex(position: vertices[0].position + SIMD3(0.003, 0, 0), color: vertices[0].color)
        let moved = builder.prepare(vertices: [nearby], animates: true, time: start + 0.2)
        XCTAssertEqual(try birth(moved, index: 0), firstBirth)
        XCTAssertEqual(moved.animationEndTime, first.animationEndTime)

        let later = builder.prepare(vertices: [nearby, vertices[1]], animates: true, time: start + 0.4)
        XCTAssertEqual(try birth(later, index: 0), firstBirth)
        XCTAssertEqual(try birth(later, index: 1), PointCloudAnimationTime.shaderTime(at: start + 0.4))
        XCTAssertEqual(try XCTUnwrap(later.animationEndTime), start + 1.2, accuracy: 0.00001)
        let repeated = builder.prepare(vertices: [vertices[1]], animates: true, time: start + 2)
        XCTAssertEqual(repeated.animationEndTime, later.animationEndTime,
                       "An existing point must not restart its flight on every preview.")
    }

    func testResetAndEmptyInputClearBirthHistory() throws {
        let builder = PointCloudRenderDataBuilder()
        let start = PointCloudAnimationTime.origin + 1
        _ = builder.prepare(vertices: fixture(), animates: true, time: start)
        builder.reset()
        let restarted = builder.prepare(vertices: fixture(), animates: true, time: start + 1)
        XCTAssertEqual(try birth(restarted, index: 0), PointCloudAnimationTime.shaderTime(at: start + 1))
        let empty = builder.prepare(vertices: [], animates: true, time: start + 2)
        XCTAssertEqual(empty.pointCount, 0)
        XCTAssertNil(empty.center)
        XCTAssertNil(empty.birthData)
        XCTAssertNil(empty.animationEndTime)
        XCTAssertTrue(empty.vertexData.isEmpty)
        let afterEmpty = builder.prepare(vertices: fixture(), animates: true, time: start + 3)
        XCTAssertEqual(try birth(afterEmpty, index: 0), PointCloudAnimationTime.shaderTime(at: start + 3))
    }

    func testSupersededPreparationDoesNotAgeUnseenParticlesOrClearVisibleHistory() throws {
        let builder = PointCloudRenderDataBuilder()
        let vertices = fixture()
        let start = PointCloudAnimationTime.origin + 10
        builder.beginPreparation()
        let visible = builder.prepare(vertices: [vertices[0]], animates: true, time: start)
        builder.finishPreparation(accepted: true)
        builder.beginPreparation()
        _ = builder.prepare(vertices: vertices, animates: true, time: start + 1)
        builder.finishPreparation(accepted: false)
        let latest = builder.prepare(vertices: vertices, animates: true, time: start + 2)
        XCTAssertEqual(try birth(latest, index: 0), try birth(visible, index: 0))
        XCTAssertEqual(try birth(latest, index: 1), PointCloudAnimationTime.shaderTime(at: start + 2),
                       "An unseen particle must start when its accepted snapshot is prepared.")
        builder.beginPreparation()
        _ = builder.prepare(vertices: [], animates: true, time: start + 3)
        builder.finishPreparation(accepted: false)
        let afterEmpty = builder.prepare(vertices: vertices, animates: true, time: start + 4)
        XCTAssertEqual(afterEmpty.birthData, latest.birthData)
        XCTAssertEqual(afterEmpty.animationEndTime, latest.animationEndTime)
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

    private func birth(_ data: PointCloudRenderData, index: Int) throws -> Float {
        try XCTUnwrap(data.birthData).withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: index * 8, as: Float.self)
        }
    }
}

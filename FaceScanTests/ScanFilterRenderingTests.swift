import SceneKit
import UIKit
import XCTest
import simd
@testable import FaceScan

final class ScanFilterRenderingTests: XCTestCase {
    @MainActor
    func testComparingFilteredAndOriginalChangesGeometryWhilePreservingViewpoint() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let original = originalMesh()
        let filtered = filteredMesh()
        let snapshot = LivePointCloudSnapshot(revision: 9, vertices: original.vertices,
                                             confirmedPointCount: original.vertexCount)
        coordinator.update(snapshot: snapshot, surfaceMesh: original,
                           resultFramingIdentity: original.renderIdentity, pointSizeScale: 2, in: view)
        await coordinator.waitForPendingUpdates()
        let node = try XCTUnwrap(view.poseNode)
        let camera = try XCTUnwrap(view.pointOfView)
        let originalGeometry = try XCTUnwrap(node.geometry)
        XCTAssertEqual(originalGeometry.elements.first?.primitiveType, .point)
        XCTAssertEqual(originalGeometry.elements.first?.pointSize ?? 0, 0.0014 * 2, accuracy: 1e-8)

        camera.position = SCNVector3(0.12, 0.08, 0.51)
        camera.eulerAngles = SCNVector3(0.1, -0.2, 0.05)
        node.simdTransform = simd_float4x4(simd_quatf(angle: 0.3, axis: SIMD3(0, 1, 0)))
        node.simdPosition = SIMD3(0.01, -0.02, 0.03)
        let cameraTransform = camera.simdTransform
        let modelTransform = node.simdTransform

        coordinator.update(snapshot: snapshot, surfaceMesh: filtered,
                           resultFramingIdentity: original.renderIdentity, pointSizeScale: 2, in: view)
        await coordinator.waitForPendingUpdates()
        let filteredGeometry = try XCTUnwrap(node.geometry)
        XCTAssertFalse(filteredGeometry === originalGeometry)
        XCTAssertEqual(filteredGeometry.elements.first?.primitiveType, .point,
                       "Filtered point clouds cannot reuse the original triangle topology.")
        XCTAssertEqual(filteredGeometry.elements.first?.pointSize ?? 0, 0.0014 * 2, accuracy: 1e-8)
        try assertGeometry(filteredGeometry, matches: filtered.vertices)
        XCTAssertEqual(camera.simdTransform, cameraTransform)
        XCTAssertEqual(node.simdTransform, modelTransform)
        XCTAssertTrue(view.accessibilityLabel?.contains(String(localized: "Filtered point cloud")) == true,
                       "The result label must use the displayed mesh rather than the stale live snapshot.")
        XCTAssertTrue(view.accessibilityLabel?.contains(L10n.pointCount(2)) == true)

        coordinator.update(snapshot: snapshot, surfaceMesh: original,
                           resultFramingIdentity: original.renderIdentity, pointSizeScale: 2, in: view)
        await coordinator.waitForPendingUpdates()
        let restoredGeometry = try XCTUnwrap(node.geometry)
        XCTAssertEqual(restoredGeometry.elements.first?.primitiveType, .point)
        XCTAssertEqual(restoredGeometry.elements.first?.pointSize ?? 0, 0.0014 * 2, accuracy: 1e-8)
        try assertGeometry(restoredGeometry, matches: original.vertices)
        XCTAssertEqual(camera.simdTransform, cameraTransform)
        XCTAssertEqual(node.simdTransform, modelTransform)
        XCTAssertTrue(view.accessibilityLabel?.contains(String(localized: "Original point cloud")) == true)
        XCTAssertTrue(view.accessibilityLabel?.contains(L10n.pointCount(3)) == true)
    }

    @MainActor
    func testAnotherScanAndClearedResultReceiveFreshFraming() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let original = originalMesh()
        coordinator.update(snapshot: nil, surfaceMesh: original,
                           resultFramingIdentity: original.renderIdentity, in: view)
        await coordinator.waitForPendingUpdates()
        let node = try XCTUnwrap(view.poseNode)
        let camera = try XCTUnwrap(view.pointOfView)
        camera.position = SCNVector3(0.12, 0.08, 0.51)
        camera.eulerAngles = SCNVector3(0.1, -0.2, 0.05)
        let userCamera = camera.simdTransform
        node.simdPosition = SIMD3(0.1, 0.2, 0.3)

        let anotherScan = filteredMesh()
        coordinator.update(snapshot: nil, surfaceMesh: anotherScan,
                           resultFramingIdentity: UUID(), in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertNotEqual(camera.simdTransform, userCamera)
        XCTAssertEqual(node.simdPosition, -center(of: anotherScan.vertices))

        coordinator.update(snapshot: nil, in: view)
        XCTAssertNil(node.geometry)
        coordinator.update(snapshot: nil, surfaceMesh: original,
                           resultFramingIdentity: original.renderIdentity, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertEqual(node.simdPosition, -center(of: original.vertices))
        XCTAssertNotNil(node.geometry)
    }

    @MainActor
    func testReturningToOriginalBeforeFilteredPreparationCompletesKeepsOriginal() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let original = originalMesh()
        coordinator.update(snapshot: nil, surfaceMesh: original,
                           resultFramingIdentity: original.renderIdentity, in: view)
        await coordinator.waitForPendingUpdates()
        let node = try XCTUnwrap(view.poseNode)
        let geometry = try XCTUnwrap(node.geometry)
        let camera = try XCTUnwrap(view.pointOfView)
        camera.position = SCNVector3(0.08, 0.03, 0.46)
        let cameraTransform = camera.simdTransform
        coordinator.update(snapshot: nil, surfaceMesh: filteredMesh(),
                           resultFramingIdentity: original.renderIdentity, in: view)
        coordinator.update(snapshot: nil, surfaceMesh: original,
                           resultFramingIdentity: original.renderIdentity, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertTrue(node.geometry === geometry)
        try assertGeometry(geometry, matches: original.vertices)
        XCTAssertEqual(camera.simdTransform, cameraTransform)
    }

    @MainActor
    private func renderer() -> (LivePointCloudSceneView, LivePointCloudView.Coordinator) {
        let view = LivePointCloudSceneView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
        let coordinator = LivePointCloudView.Coordinator()
        coordinator.install(in: view)
        return (view, coordinator)
    }

    private func originalMesh() -> ScanMesh {
        ScanMesh(vertices: [
            ScanVertex(position: SIMD3(-0.04, 0.05, 0), color: SIMD3(0.9, 0.3, 0.1)),
            ScanVertex(position: SIMD3(0.04, 0.05, 0), color: SIMD3(0.2, 0.8, 0.3)),
            ScanVertex(position: SIMD3(0, -0.04, 0), color: SIMD3(0.2, 0.4, 0.9))
        ], triangleIndices: [0, 1, 2], frameCount: 8, coveredAngles: [.center])
    }

    private func filteredMesh() -> ScanMesh {
        var mesh = ScanMesh(vertices: [
            ScanVertex(position: SIMD3(-0.038, 0.05, 0.002), color: SIMD3(0.8, 0.35, 0.15)),
            ScanVertex(position: SIMD3(0.039, -0.039, 0.001), color: SIMD3(0.25, 0.5, 0.7))
        ], triangleIndices: [], frameCount: 8, coveredAngles: [.center])
        mesh.isFiltered = true
        return mesh
    }

    private func center(of vertices: [ScanVertex]) -> SIMD3<Float> {
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        for vertex in vertices {
            low = simd_min(low, vertex.position)
            high = simd_max(high, vertex.position)
        }
        return (low + high) * 0.5
    }

    private func assertGeometry(_ geometry: SCNGeometry, matches vertices: [ScanVertex],
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let positions = try XCTUnwrap(geometry.sources(for: .vertex).first, file: file, line: line)
        let colors = try XCTUnwrap(geometry.sources(for: .color).first, file: file, line: line)
        XCTAssertEqual(positions.vectorCount, vertices.count, file: file, line: line)
        for index in vertices.indices {
            XCTAssertEqual(vector(in: positions, index: index), vertices[index].position, file: file, line: line)
            XCTAssertEqual(vector(in: colors, index: index), vertices[index].color, file: file, line: line)
        }
    }

    private func vector(in source: SCNGeometrySource, index: Int) -> SIMD3<Float> {
        source.data.withUnsafeBytes { bytes in
            let offset = source.dataOffset + index * source.dataStride
            return SIMD3(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self),
                         bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                         bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self))
        }
    }
}

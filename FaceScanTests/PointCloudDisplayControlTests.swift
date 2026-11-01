import SceneKit
import UIKit
import XCTest
import simd
@testable import FaceScan

final class PointCloudDisplayControlTests: XCTestCase {
    @MainActor
    func testPointSizeUpdatesReusePreparedSourcesAndTheSharedPointElement() throws {
        let resources = PointCloudRenderResources()
        let data = PointCloudRenderDataBuilder().prepare(vertices: fixture(), triangleIndices: [0, 1, 2])
        let prepared = resources.make(data: data)
        let points = try XCTUnwrap(prepared.points)
        let element = try XCTUnwrap(points.elements.first)
        let positions = try XCTUnwrap(points.sources(for: .vertex).first)
        let colors = try XCTUnwrap(points.sources(for: .color).first)
        let originalBytes = positions.data

        XCTAssertTrue(resources.updatePointSizeScale(2.5))
        XCTAssertFalse(resources.updatePointSizeScale(2.5))
        assertSize(element, scale: 2.5)
        XCTAssertTrue(points.elements.first === element)
        XCTAssertTrue(points.sources(for: .vertex).first === positions)
        XCTAssertTrue(points.sources(for: .color).first === colors)
        XCTAssertEqual(positions.data, originalBytes)
        XCTAssertTrue(prepared.surface?.sources(for: .vertex).first === positions)
        XCTAssertEqual(prepared.surface?.elements.first?.primitiveType, .triangles)

        let replacement = resources.make(data: PointCloudRenderDataBuilder().prepare(vertices: Array(fixture().prefix(2))))
        let replacementElement = try XCTUnwrap(replacement.points?.elements.first)
        XCTAssertFalse(replacementElement === element)
        assertSize(replacementElement, scale: 2.5)
    }

    @MainActor
    func testLivePointSizeChangesPreserveBuffersCameraAndHeadPose() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations(); view.stopRenderUpdates() }
        let store = LiveFacePoseStore()
        let rotation = simd_float4x4(simd_quatf(angle: 0.3, axis: SIMD3(0, 1, 0)))
        XCTAssertTrue(store.update(faceToCamera: rotation))
        let snapshot = LivePointCloudSnapshot(revision: 1, vertices: fixture(), confirmedPointCount: 3)
        coordinator.update(snapshot: snapshot, poseStore: store, followsFacePose: true,
                           animatesAcquisition: true, in: view)
        await coordinator.waitForPendingUpdates()
        let node = try XCTUnwrap(view.poseNode)
        let geometry = try XCTUnwrap(node.geometry)
        let positions = try XCTUnwrap(geometry.sources(for: .vertex).first)
        let camera = try XCTUnwrap(view.pointOfView)
        let cameraTransform = camera.simdTransform
        let pose = node.simdTransform
        XCTAssertEqual(pose, rotation)

        coordinator.update(snapshot: snapshot, poseStore: store, followsFacePose: true,
                           animatesAcquisition: true, pointSizeScale: 0.5, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertTrue(node.geometry === geometry, "Sizing must not enqueue another vertex preparation.")
        XCTAssertTrue(node.geometry?.sources(for: .vertex).first === positions)
        XCTAssertEqual(camera.simdTransform, cameraTransform)
        XCTAssertEqual(node.simdTransform, pose)
        XCTAssertFalse(view.allowsCameraControl)
        assertSize(try XCTUnwrap(node.geometry?.elements.first), scale: 0.5)
    }

    @MainActor
    func testCompletedPointSizingPreservesComparisonViewpointAndAccessibility() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations(); view.stopRenderUpdates() }
        let mesh = ScanMesh(vertices: fixture(), triangleIndices: [], frameCount: 8,
                            coveredAngles: [.center], isFiltered: true)
        coordinator.update(snapshot: nil, surfaceMesh: mesh, resultFramingIdentity: mesh.renderIdentity,
                           in: view)
        await coordinator.waitForPendingUpdates()
        let node = try XCTUnwrap(view.poseNode)
        let geometry = try XCTUnwrap(node.geometry)
        let camera = try XCTUnwrap(view.pointOfView)
        camera.position = SCNVector3(0.12, 0.08, 0.51)
        camera.eulerAngles = SCNVector3(0.1, -0.2, 0.05)
        node.simdTransform = simd_float4x4(simd_quatf(angle: 0.3, axis: SIMD3(0, 1, 0)))
        let cameraTransform = camera.simdTransform
        let pose = node.simdTransform

        coordinator.update(snapshot: nil, surfaceMesh: mesh, resultFramingIdentity: mesh.renderIdentity,
                           pointSizeScale: 3, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertTrue(node.geometry === geometry, "Sizing must reuse the completed point geometry.")
        assertSize(try XCTUnwrap(node.geometry?.elements.first), scale: 3)
        XCTAssertEqual(camera.simdTransform, cameraTransform)
        XCTAssertEqual(node.simdTransform, pose)
        XCTAssertTrue(view.accessibilityLabel?.contains(String(localized: "Filtered point cloud")) == true)
        XCTAssertTrue(view.accessibilityLabel?.contains(L10n.pointCount(3)) == true)
        coordinator.update(snapshot: nil, surfaceMesh: mesh, resultFramingIdentity: mesh.renderIdentity,
                           pointSizeScale: 1, in: view)
        XCTAssertTrue(view.accessibilityLabel?.contains(String(localized: "Filtered point cloud")) == true)
        XCTAssertTrue(view.accessibilityLabel?.contains(L10n.pointCount(3)) == true)
    }

    @MainActor
    func testPendingPreparationUsesTheLatestSizeWithoutReplacingItsInput() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations(); view.stopRenderUpdates() }
        let snapshot = LivePointCloudSnapshot(revision: 1, vertices: fixture(), confirmedPointCount: 3)
        coordinator.update(snapshot: snapshot, animatesAcquisition: true, pointSizeScale: 0.5, in: view)
        coordinator.update(snapshot: snapshot, animatesAcquisition: true, pointSizeScale: 2, in: view)
        coordinator.update(snapshot: snapshot, animatesAcquisition: true, pointSizeScale: 4, in: view)
        await coordinator.waitForPendingUpdates()
        let geometry = try XCTUnwrap(view.poseNode?.geometry)
        assertSize(try XCTUnwrap(geometry.elements.first), scale: 4)
        let positions = try XCTUnwrap(geometry.sources(for: .vertex).first)
        XCTAssertEqual(positions.vectorCount, fixture().count)
        XCTAssertEqual(positions.data.count, fixture().count * 24)
    }

    @MainActor
    func testSizeInputsAreBoundedAndLegacyGeometryUsesTheSameScaleRules() throws {
        let resources = PointCloudRenderResources()
        let data = PointCloudRenderDataBuilder().prepare(vertices: fixture())
        let element = try XCTUnwrap(resources.make(data: data).points?.elements.first)
        for (input, expected) in [(0.0, 0.25), (-10, 0.25), (100, 4), (Double.nan, 1),
                                  (Double.infinity, 1), (-Double.infinity, 1)] {
            resources.updatePointSizeScale(input)
            assertSize(element, scale: expected)
            let legacy = try XCTUnwrap(LivePointGeometryBuilder.makeGeometry(vertices: fixture(), pointSizeScale: input))
            assertSize(try XCTUnwrap(legacy.elements.first), scale: expected)
        }
        let defaultGeometry = try XCTUnwrap(LivePointGeometryBuilder.makeGeometry(vertices: fixture()))
        assertSize(try XCTUnwrap(defaultGeometry.elements.first), scale: 1)
    }

    @MainActor
    private func renderer() -> (LivePointCloudSceneView, LivePointCloudView.Coordinator) {
        let view = LivePointCloudSceneView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
        let coordinator = LivePointCloudView.Coordinator()
        coordinator.install(in: view)
        return (view, coordinator)
    }

    private func fixture() -> [ScanVertex] {
        [ScanVertex(position: SIMD3(-0.04, 0.05, 0), color: SIMD3(0.9, 0.3, 0.1)),
         ScanVertex(position: SIMD3(0.04, 0.05, 0), color: SIMD3(0.2, 0.8, 0.3)),
         ScanVertex(position: SIMD3(0, -0.04, 0), color: SIMD3(0.2, 0.4, 0.9))]
    }

    private func assertSize(_ element: SCNGeometryElement, scale: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(element.pointSize, 0.0014 * scale, accuracy: 1e-8, file: file, line: line)
        XCTAssertEqual(element.minimumPointScreenSpaceRadius, 1.4 * scale, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(element.maximumPointScreenSpaceRadius, 2 * scale, accuracy: 1e-6, file: file, line: line)
    }
}

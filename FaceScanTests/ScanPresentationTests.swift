import SceneKit
import UIKit
import XCTest
import simd
@testable import FaceScan

final class ScanPresentationTests: XCTestCase {
    func testOriginalColorUsesMeasuredFacesAndPreservesVertexColors() throws {
        let bad = ScanVertex(position: SIMD3(.nan, 0, 0), color: SIMD3(repeating: 0.5))
        let vertices = fixture()
        let mesh = ScanMesh(vertices: [bad] + vertices,
                            triangleIndices: [1, 2, 3, 0, 2, 3, 1, 2, 99],
                            frameCount: 5, coveredAngles: [])
        let geometry = try XCTUnwrap(LivePointGeometryBuilder.makeSurfaceGeometry(mesh: mesh))
        let element = try XCTUnwrap(geometry.elements.first)
        XCTAssertEqual(element.primitiveType, .triangles)
        XCTAssertEqual(element.primitiveCount, 1)
        XCTAssertEqual(element.data.withUnsafeBytes { bytes in
            (0..<3).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
        }, [0, 1, 2])
        let positions = try XCTUnwrap(geometry.sources(for: .vertex).first)
        let colors = try XCTUnwrap(geometry.sources(for: .color).first)
        for index in vertices.indices {
            XCTAssertEqual(vector(in: positions, index: index), vertices[index].position)
            XCTAssertEqual(vector(in: colors, index: index), vertices[index].color)
        }
        XCTAssertEqual(geometry.firstMaterial?.lightingModel, .constant)
    }

    func testPointOnlyScanRemainsVisibleInOriginalColorMode() throws {
        let vertices = fixture()
        let mesh = ScanMesh(vertices: vertices, triangleIndices: [], frameCount: 5, coveredAngles: [])
        let geometry = try XCTUnwrap(LivePointGeometryBuilder.makeSurfaceGeometry(mesh: mesh))
        XCTAssertEqual(geometry.elements.first?.primitiveType, .point)
        XCTAssertEqual(geometry.elements.first?.primitiveCount, vertices.count)
        XCTAssertTrue(mesh.triangleIndices.isEmpty)
    }

    @MainActor
    func testSwitchingResultModeKeepsCameraAndFrozenHeadPose() throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let mesh = ScanMesh(vertices: fixture(), triangleIndices: [0, 1, 2],
                            frameCount: 5, coveredAngles: [])
        let snapshot = LivePointCloudSnapshot(revision: 6, vertices: mesh.vertices, confirmedPointCount: 3)
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, in: view)
        let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "livePointCloud", recursively: false))
        let camera = try XCTUnwrap(view.pointOfView)
        camera.position = SCNVector3(0.12, 0.08, 0.51)
        camera.eulerAngles = SCNVector3(0.1, -0.2, 0.05)
        node.simdTransform = simd_float4x4(simd_quatf(angle: 0.3, axis: SIMD3(0, 1, 0)))
        let cameraTransform = camera.simdTransform
        let headTransform = node.simdTransform
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, displayStyle: .color, in: view)
        XCTAssertEqual(node.geometry?.elements.first?.primitiveType, .triangles)
        let geometry = node.geometry
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, displayStyle: .color, in: view)
        XCTAssertTrue(node.geometry === geometry)
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, displayStyle: .points, in: view)
        XCTAssertEqual(node.geometry?.elements.first?.primitiveType, .point)
        XCTAssertEqual(camera.simdTransform, cameraTransform)
        XCTAssertEqual(node.simdTransform, headTransform)
    }

    @MainActor
    func testCompletedResultsCenterIndependentlyOfCapturePositionAndAngle() throws {
        let vertices = fixture().map {
            ScanVertex(position: $0.position + SIMD3(0.027, -0.019, 0.013), color: $0.color)
        }
        let mesh = ScanMesh(vertices: vertices, triangleIndices: [0, 1, 2],
                            frameCount: 8, coveredAngles: [])
        let center = SIMD3<Float>(0.027, -0.014, 0.013)
        for index in 0..<2 {
            let (view, coordinator) = renderer()
            defer { coordinator.stopAnimations() }
            let store = LiveFacePoseStore()
            var pose = simd_float4x4(simd_quatf(angle: Float(index) * 0.4,
                                              axis: SIMD3(0, 1, 0)))
            pose.columns.3 = SIMD4(Float(index) * 0.16, -0.06, -0.35, 1)
            store.update(faceToCamera: pose)
            let scan = LivePointCloudSnapshot(revision: 7, vertices: vertices, confirmedPointCount: 3)
            coordinator.update(snapshot: scan, poseStore: store, followsFacePose: true,
                               animatesAcquisition: true, in: view)
            pose = simd_float4x4(simd_quatf(angle: index == 0 ? -0.5 : 0.6,
                                          axis: SIMD3(0, 1, 0)))
            pose.columns.3 = SIMD4(index == 0 ? -0.12 : 0.25, 0.08, -0.43, 1)
            store.update(faceToCamera: pose)
            view.applyLatestFacePose()
            let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "livePointCloud", recursively: false))
            let camera = try XCTUnwrap(view.pointOfView)
            let captureDepth = -camera.simdConvertPosition(node.simdConvertPosition(center, to: nil), from: nil).z
            let capturedTransform = node.simdTransform
            coordinator.update(snapshot: scan, poseStore: store, in: view)
            XCTAssertEqual(node.simdTransform, capturedTransform, "Keep processing stable until the final data arrives.")
            coordinator.update(snapshot: scan, poseStore: store, surfaceMesh: mesh, in: view)
            let worldCenter = node.convertPosition(SCNVector3(center), to: nil)
            XCTAssertEqual(worldCenter.x, 0, accuracy: 1e-7)
            XCTAssertEqual(worldCenter.y, 0, accuracy: 1e-7)
            XCTAssertEqual(worldCenter.z, 0, accuracy: 1e-7)
            XCTAssertEqual(node.simdOrientation, simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)))
            let projected = view.projectPoint(worldCenter)
            XCTAssertEqual(projected.x, Float(view.bounds.midX), accuracy: 0.001)
            XCTAssertEqual(projected.y, Float(view.bounds.midY), accuracy: 0.001)
            XCTAssertEqual(view.defaultCameraController.target.x, 0)
            XCTAssertEqual(view.defaultCameraController.target.y, 0)
            XCTAssertEqual(view.defaultCameraController.target.z, 0)
            XCTAssertTrue(view.defaultCameraController.pointOfView === camera)
            XCTAssertEqual(camera.simdPosition.z, captureDepth, accuracy: 1e-7,
                           "Centering preserves the scan's optical depth rather than fitting a new zoom.")
            let positions = try XCTUnwrap(node.geometry?.sources(for: .vertex).first)
            for vertexIndex in vertices.indices {
                XCTAssertEqual(vector(in: positions, index: vertexIndex), vertices[vertexIndex].position,
                               "Centering must not rewrite source or exported coordinates.")
                let point = view.projectPoint(node.convertPosition(SCNVector3(vertices[vertexIndex].position), to: nil))
                XCTAssertTrue((0...Float(view.bounds.width)).contains(point.x))
                XCTAssertTrue((0...Float(view.bounds.height)).contains(point.y))
            }
            store.update(faceToCamera: matrix_identity_float4x4)
            view.applyLatestFacePose()
            let afterPoseUpdate = node.convertPosition(SCNVector3(center), to: nil)
            XCTAssertEqual(SIMD3(afterPoseUpdate.x, afterPoseUpdate.y, afterPoseUpdate.z),
                           SIMD3(worldCenter.x, worldCenter.y, worldCenter.z))
        }
    }

    @MainActor
    func testRecenteringPreservesScanSizeWhenResultControlsReduceViewport() throws {
        for resizeBeforeResult in [false, true] {
            let (view, coordinator) = renderer()
            defer { coordinator.stopAnimations() }
            let store = LiveFacePoseStore()
            var pose = matrix_identity_float4x4
            pose.columns.3 = SIMD4(0.1, -0.03, -0.4, 1)
            store.update(faceToCamera: pose)
            let vertices = fixture().map {
                ScanVertex(position: $0.position + SIMD3(0.025, -0.02, 0.04), color: $0.color)
            }
            let mesh = ScanMesh(vertices: vertices, triangleIndices: [0, 1, 2],
                                frameCount: 8, coveredAngles: [])
            let scan = LivePointCloudSnapshot(revision: 7, vertices: vertices, confirmedPointCount: 3)
            coordinator.update(snapshot: scan, poseStore: store, followsFacePose: true,
                               animatesAcquisition: true, in: view)
            pose.columns.3 = SIMD4(0.16, 0.02, -0.34, 1)
            store.update(faceToCamera: pose)
            view.applyLatestFacePose()
            let node = try XCTUnwrap(view.poseNode)
            let captureSize = projectedSize(vertices: vertices, node: node, in: view)
            coordinator.update(snapshot: scan, poseStore: store, in: view)
            if resizeBeforeResult {
                view.frame.size.height = 410
                view.layoutIfNeeded()
            }
            coordinator.update(snapshot: scan, poseStore: store, surfaceMesh: mesh, in: view)
            if !resizeBeforeResult {
                view.frame.size.height = 410
                view.layoutIfNeeded()
            }
            let resultSize = projectedSize(vertices: vertices, node: node, in: view)
            XCTAssertEqual(resultSize.x, captureSize.x, accuracy: 0.001)
            XCTAssertEqual(resultSize.y, captureSize.y, accuracy: 0.001)
        }
    }

    @MainActor
    func testResultArrivingBeforeFirstLayoutRetainsCaptureScale() throws {
        let vertices = fixture()
        let mesh = ScanMesh(vertices: vertices, triangleIndices: [0, 1, 2],
                            frameCount: 5, coveredAngles: [])
        let scan = LivePointCloudSnapshot(revision: 6, vertices: vertices, confirmedPointCount: 3)
        let (capture, captureCoordinator) = renderer()
        defer { captureCoordinator.stopAnimations() }
        captureCoordinator.update(snapshot: scan, in: capture)
        let captureNode = try XCTUnwrap(capture.poseNode)
        let captureSize = projectedSize(vertices: vertices, node: captureNode, in: capture)

        let result = LivePointCloudSceneView(frame: .zero)
        let resultCoordinator = LivePointCloudView.Coordinator()
        defer { resultCoordinator.stopAnimations() }
        resultCoordinator.install(in: result)
        resultCoordinator.update(snapshot: scan, surfaceMesh: mesh, in: result)
        result.frame = capture.frame
        result.setNeedsLayout()
        result.layoutIfNeeded()
        XCTAssertFalse(result.needsInitialFit)
        XCTAssertGreaterThan(try XCTUnwrap(result.pointOfView).position.z, 0.01)
        _ = result.snapshot()
        let resultNode = try XCTUnwrap(result.poseNode)
        let resultSize = projectedSize(vertices: vertices, node: resultNode, in: result)
        XCTAssertEqual(resultSize.x, captureSize.x, accuracy: 0.001)
        XCTAssertEqual(resultSize.y, captureSize.y, accuracy: 0.001)
        XCTAssertEqual(result.projectPoint(SCNVector3Zero).x, Float(result.bounds.midX), accuracy: 0.001)
        XCTAssertEqual(result.projectPoint(SCNVector3Zero).y, Float(result.bounds.midY), accuracy: 0.001)
    }

    @MainActor
    func testFinalMeshArrivingAfterProcessingCentersOnceThenPreservesUserView() throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let partial = LivePointCloudSnapshot(revision: 3, vertices: [fixture()[0]], confirmedPointCount: 1)
        coordinator.update(snapshot: partial, animatesAcquisition: true, in: view)
        coordinator.update(snapshot: partial, in: view)
        let camera = try XCTUnwrap(view.pointOfView)
        let processingCamera = camera.simdTransform
        let vertices = fixture().map {
            ScanVertex(position: $0.position * 2 + SIMD3(0.055, 0.04, -0.02), color: $0.color)
        }
        let mesh = ScanMesh(vertices: vertices, triangleIndices: [0, 1, 2],
                            frameCount: 9, coveredAngles: [])
        coordinator.update(snapshot: partial, surfaceMesh: mesh, in: view)
        XCTAssertNotEqual(camera.simdTransform, processingCamera)
        let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "livePointCloud", recursively: false))
        let centeredTransform = node.simdTransform
        let center = SCNVector3(0.055, 0.05, -0.02)
        let projected = view.projectPoint(node.convertPosition(center, to: nil))
        XCTAssertEqual(projected.x, Float(view.bounds.midX), accuracy: 0.001)
        XCTAssertEqual(projected.y, Float(view.bounds.midY), accuracy: 0.001)

        camera.position = SCNVector3(0.15, 0.08, 0.42)
        camera.eulerAngles = SCNVector3(0.08, 0.25, 0)
        let userCamera = camera.simdTransform
        let final = LivePointCloudSnapshot(revision: 10, vertices: vertices, confirmedPointCount: 3)
        coordinator.update(snapshot: final, surfaceMesh: mesh, displayStyle: .color, in: view)
        coordinator.update(snapshot: final, surfaceMesh: mesh, displayStyle: .points, in: view)
        coordinator.update(snapshot: final, surfaceMesh: mesh, displayStyle: .points, in: view)
        XCTAssertEqual(camera.simdTransform, userCamera)
        XCTAssertEqual(node.simdTransform, centeredTransform)
    }

    @MainActor
    func testNewScanReturnsFromCenteredResultToLivePoseFraming() throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let mesh = ScanMesh(vertices: fixture(), triangleIndices: [0, 1, 2],
                            frameCount: 5, coveredAngles: [])
        let snapshot = LivePointCloudSnapshot(revision: 6, vertices: mesh.vertices, confirmedPointCount: 3)
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, in: view)
        let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "livePointCloud", recursively: false))
        XCTAssertNotEqual(node.simdTransform, matrix_identity_float4x4)
        let store = LiveFacePoseStore()
        var pose = simd_float4x4(simd_quatf(angle: 0.25, axis: SIMD3(0, 1, 0)))
        pose.columns.3 = SIMD4(0.12, 0.02, -0.42, 1)
        store.update(faceToCamera: pose)
        coordinator.update(snapshot: snapshot, poseStore: store, followsFacePose: true,
                           animatesAcquisition: true, in: view)
        XCTAssertEqual(node.simdTransform, store.latestPose?.transform)
        XCTAssertEqual(view.defaultCameraController.target.x, LivePointCloudSceneView.faceCenter.x)
        XCTAssertEqual(view.defaultCameraController.target.y, LivePointCloudSceneView.faceCenter.y)
        XCTAssertEqual(view.defaultCameraController.target.z, LivePointCloudSceneView.faceCenter.z)
        XCTAssertFalse(view.allowsCameraControl)
    }

    @MainActor
    func testNewPointsFlyOnceAndStopImmediatelySettles() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let vertices = fixture()
        let first = LivePointCloudSnapshot(revision: 1, vertices: [vertices[0]], confirmedPointCount: 1)
        coordinator.update(snapshot: first, animatesAcquisition: true, in: view)
        let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "livePointCloud", recursively: false))
        let firstGeometry = try XCTUnwrap(node.geometry)
        let birth = try birthTime(in: firstGeometry, index: 0)
        XCTAssertGreaterThanOrEqual(birth, 0)
        XCTAssertTrue(view.rendersContinuously)
        coordinator.update(snapshot: first, animatesAcquisition: true, in: view)
        XCTAssertTrue(node.geometry === firstGeometry)
        try await Task.sleep(for: .milliseconds(30))
        let next = LivePointCloudSnapshot(revision: 2, vertices: vertices, confirmedPointCount: 3)
        coordinator.update(snapshot: next, animatesAcquisition: true, in: view)
        let updated = try XCTUnwrap(node.geometry)
        XCTAssertEqual(try birthTime(in: updated, index: 0), birth)
        XCTAssertGreaterThan(try birthTime(in: updated, index: 1), birth)
        let cameraTransform = view.pointOfView?.simdTransform
        coordinator.update(snapshot: next, animatesAcquisition: false, in: view)
        XCTAssertEqual((updated.firstMaterial?.value(forKey: "pointFlightEnabled") as? NSNumber)?.floatValue, 0)
        XCTAssertFalse(view.rendersContinuously)
        XCTAssertFalse(view.isPlaying)
        XCTAssertTrue(node.geometry === updated)
        XCTAssertEqual(view.pointOfView?.simdTransform, cameraTransform)
        coordinator.update(snapshot: next, animatesAcquisition: true, in: view)
        XCTAssertGreaterThan(try birthTime(in: XCTUnwrap(node.geometry), index: 0), birth)
        coordinator.update(snapshot: nil, animatesAcquisition: true, in: view)
        XCTAssertNil(node.geometry)
        XCTAssertFalse(view.rendersContinuously)
        coordinator.update(snapshot: first, animatesAcquisition: true, in: view)
        XCTAssertGreaterThan(try birthTime(in: XCTUnwrap(node.geometry), index: 0), birth)
    }

    @MainActor
    func testFlightEndsItsRenderLoopWithoutMoreSnapshots() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 1, vertices: fixture(),
                                                            confirmedPointCount: 3),
                           animatesAcquisition: true, in: view)
        XCTAssertTrue(view.rendersContinuously)
        try await Task.sleep(for: .seconds(PointCloudFlight.duration + 0.15))
        XCTAssertFalse(view.rendersContinuously)
        XCTAssertFalse(view.isPlaying)
    }

    @MainActor
    func testLaterPointsExtendCompletionDeadline() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let vertices = fixture()
        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 1, vertices: [vertices[0]],
                                                            confirmedPointCount: 1),
                           animatesAcquisition: true, in: view)
        try await Task.sleep(for: .milliseconds(500))
        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 2, vertices: vertices,
                                                            confirmedPointCount: 3),
                           animatesAcquisition: true, in: view)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(view.rendersContinuously, "The old deadline must not stop newly acquired particles.")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(view.rendersContinuously)
        XCTAssertFalse(view.isPlaying)
    }

    @MainActor
    func testGPUFlightDoesNotRotateOrMovePointsSideways() throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        view.pointOfView?.camera?.usesOrthographicProjection = true
        view.pointOfView?.camera?.orthographicScale = 0.3
        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 1, vertices: fixture(),
                                                            confirmedPointCount: 3),
                           animatesAcquisition: true, in: view)
        let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "livePointCloud", recursively: false))
        let material = try XCTUnwrap(node.geometry?.firstMaterial)
        let birth = try birthTime(in: XCTUnwrap(node.geometry), index: 0)
        material.setValue(birth, forKey: "pointFlightTime")
        let flying = try XCTUnwrap(view.snapshot().cgImage?.dataProvider?.data) as Data
        material.setValue(birth + Float(PointCloudFlight.duration), forKey: "pointFlightTime")
        let arrived = try XCTUnwrap(view.snapshot().cgImage?.dataProvider?.data) as Data
        XCTAssertEqual(flying, arrived, "Orthographic X/Y must stay fixed throughout the straight depth-only flight.")
        node.isHidden = true
        let empty = try XCTUnwrap(view.snapshot().cgImage?.dataProvider?.data) as Data
        XCTAssertNotEqual(arrived, empty, "The shader must actually render visible particles.")
        XCTAssertEqual(node.simdTransform, matrix_identity_float4x4)
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

    @MainActor
    private func projectedSize(vertices: [ScanVertex], node: SCNNode, in view: SCNView) -> SIMD2<Float> {
        let points = vertices.map { view.projectPoint(node.convertPosition(SCNVector3($0.position), to: nil)) }
        return SIMD2(points.map(\.x).max()! - points.map(\.x).min()!,
                     points.map(\.y).max()! - points.map(\.y).min()!)
    }

    private func vector(in source: SCNGeometrySource, index: Int) -> SIMD3<Float> {
        source.data.withUnsafeBytes { bytes in
            let offset = source.dataOffset + index * source.dataStride
            return SIMD3(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self),
                         bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                         bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self))
        }
    }

    private func birthTime(in geometry: SCNGeometry, index: Int) throws -> Float {
        let source = try XCTUnwrap(geometry.sources(for: .texcoord).first)
        return source.data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: source.dataOffset + index * source.dataStride, as: Float.self)
        }
    }
}

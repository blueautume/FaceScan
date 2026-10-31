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
    func testSwitchingResultModeKeepsCameraAndFrozenHeadPose() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let mesh = ScanMesh(vertices: fixture(), triangleIndices: [0, 1, 2],
                            frameCount: 5, coveredAngles: [])
        let snapshot = LivePointCloudSnapshot(revision: 6, vertices: mesh.vertices, confirmedPointCount: 3)
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, in: view)
        await coordinator.waitForPendingUpdates()
        let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "livePointCloud", recursively: false))
        let pointGeometry = try XCTUnwrap(node.geometry)
        let pointPositions = try XCTUnwrap(pointGeometry.sources(for: .vertex).first)
        let pointColors = try XCTUnwrap(pointGeometry.sources(for: .color).first)
        let camera = try XCTUnwrap(view.pointOfView)
        camera.position = SCNVector3(0.12, 0.08, 0.51)
        camera.eulerAngles = SCNVector3(0.1, -0.2, 0.05)
        node.simdTransform = simd_float4x4(simd_quatf(angle: 0.3, axis: SIMD3(0, 1, 0)))
        let cameraTransform = camera.simdTransform
        let headTransform = node.simdTransform
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, displayStyle: .color, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertEqual(node.geometry?.elements.first?.primitiveType, .triangles)
        XCTAssertTrue(node.geometry?.sources(for: .vertex).first === pointPositions)
        XCTAssertTrue(node.geometry?.sources(for: .color).first === pointColors)
        XCTAssertTrue(node.geometry?.firstMaterial === pointGeometry.firstMaterial)
        let geometry = node.geometry
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, displayStyle: .color, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertTrue(node.geometry === geometry)
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, displayStyle: .points, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertEqual(node.geometry?.elements.first?.primitiveType, .point)
        XCTAssertTrue(node.geometry === pointGeometry, "Returning to point mode must reuse the prepared result.")
        XCTAssertEqual(camera.simdTransform, cameraTransform)
        XCTAssertEqual(node.simdTransform, headTransform)
    }

    @MainActor
    func testEqualSizedReplacementResultInvalidatesCachedGeometry() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let first = ScanMesh(vertices: fixture(), triangleIndices: [0, 1, 2],
                             frameCount: 5, coveredAngles: [])
        let snapshot = LivePointCloudSnapshot(revision: 6, vertices: first.vertices, confirmedPointCount: 3)
        coordinator.update(snapshot: snapshot, surfaceMesh: first, displayStyle: .color, in: view)
        await coordinator.waitForPendingUpdates()
        let node = try XCTUnwrap(view.poseNode)
        let firstGeometry = try XCTUnwrap(node.geometry)

        let replacement = ScanMesh(vertices: fixture().map {
            ScanVertex(position: $0.position + SIMD3(0.02, -0.01, 0.03), color: SIMD3(0.3, 0.4, 0.5))
        }, triangleIndices: [0, 1, 2], frameCount: 5, coveredAngles: [])
        coordinator.update(snapshot: snapshot, surfaceMesh: replacement, displayStyle: .color, in: view)
        await coordinator.waitForPendingUpdates()
        let replacementGeometry = try XCTUnwrap(node.geometry)
        XCTAssertFalse(replacementGeometry === firstGeometry,
                       "Two scans with equal revision and counts must not share stale cached geometry.")
        let positions = try XCTUnwrap(replacementGeometry.sources(for: .vertex).first)
        let colors = try XCTUnwrap(replacementGeometry.sources(for: .color).first)
        for index in replacement.vertices.indices {
            XCTAssertEqual(vector(in: positions, index: index), replacement.vertices[index].position)
            XCTAssertEqual(vector(in: colors, index: index), replacement.vertices[index].color)
        }
        coordinator.update(snapshot: snapshot, surfaceMesh: replacement, displayStyle: .points, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertTrue(node.geometry?.sources(for: .vertex).first === positions)
    }

    @MainActor
    func testMutatingCopiedMeshInvalidatesCacheWithoutChangingRawCoordinates() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let original = ScanMesh(vertices: fixture(), triangleIndices: [0, 1, 2],
                                frameCount: 5, coveredAngles: [])
        let snapshot = LivePointCloudSnapshot(revision: 6, vertices: original.vertices, confirmedPointCount: 3)
        coordinator.update(snapshot: snapshot, surfaceMesh: original, displayStyle: .color, in: view)
        await coordinator.waitForPendingUpdates()
        let node = try XCTUnwrap(view.poseNode)
        let originalGeometry = try XCTUnwrap(node.geometry)
        var copy = original
        XCTAssertEqual(copy.renderIdentity, original.renderIdentity)
        copy.vertices[0].position += SIMD3(0.015, -0.01, 0.02)
        copy.vertices[0].color = SIMD3(0.25, 0.5, 0.75)
        XCTAssertNotEqual(copy.renderIdentity, original.renderIdentity)
        coordinator.update(snapshot: snapshot, surfaceMesh: copy, displayStyle: .color, in: view)
        await coordinator.waitForPendingUpdates()
        let copiedGeometry = try XCTUnwrap(node.geometry)
        XCTAssertFalse(copiedGeometry === originalGeometry)
        let copiedPositions = try XCTUnwrap(copiedGeometry.sources(for: .vertex).first)
        let copiedColors = try XCTUnwrap(copiedGeometry.sources(for: .color).first)
        XCTAssertEqual(vector(in: copiedPositions, index: 0), copy.vertices[0].position)
        XCTAssertEqual(vector(in: copiedColors, index: 0), copy.vertices[0].color)
        XCTAssertEqual(original.vertices[0].position, fixture()[0].position)
        XCTAssertEqual(original.vertices[0].color, fixture()[0].color)

        let vertexIdentity = copy.renderIdentity
        copy.triangleIndices = [0, 2, 1]
        XCTAssertNotEqual(copy.renderIdentity, vertexIdentity)
        coordinator.update(snapshot: snapshot, surfaceMesh: copy, displayStyle: .color, in: view)
        await coordinator.waitForPendingUpdates()
        let changedFaces = try XCTUnwrap(node.geometry?.elements.first)
        XCTAssertFalse(node.geometry === copiedGeometry)
        XCTAssertEqual(changedFaces.data.withUnsafeBytes { bytes in
            (0..<3).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
        }, [0, 2, 1])
        XCTAssertEqual(original.triangleIndices, [0, 1, 2])

        let exportedMesh = copy
        let url = try await Task.detached { try ScanExporter.export(exportedMesh) }.value
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        let body = try XCTUnwrap(text.components(separatedBy: "end_header\n").last)
        let lines = body.split(separator: "\n")
        for index in copy.vertices.indices {
            let fields = lines[index].split(separator: " ")
            let expected = copy.vertices[index].position
            XCTAssertEqual(try XCTUnwrap(Float(fields[0])), expected.x)
            XCTAssertEqual(try XCTUnwrap(Float(fields[1])), expected.y)
            XCTAssertEqual(try XCTUnwrap(Float(fields[2])), expected.z,
                           "The 1.7× display magnification must not enter exported meter coordinates.")
        }
    }

    @MainActor
    func testPendingAcquisitionCannotReappearAfterClearOrTeardown() async throws {
        let vertices = largeFixture()
        for teardown in [false, true] {
            let (view, coordinator) = renderer()
            defer { coordinator.stopAnimations() }
            coordinator.update(snapshot: LivePointCloudSnapshot(revision: 20, vertices: vertices,
                                                                confirmedPointCount: vertices.count),
                               animatesAcquisition: true, in: view)
            // Both invalidations happen before the main actor can install any prepared result.
            if teardown {
                coordinator.stopAnimations()
            } else {
                coordinator.update(snapshot: nil, animatesAcquisition: true, in: view)
            }
            await coordinator.waitForPendingUpdates()
            XCTAssertNil(view.poseNode?.geometry)
            XCTAssertFalse(view.rendersContinuously)
            XCTAssertFalse(view.isPlaying)
        }
    }

    @MainActor
    func testStoppingWhilePreparationIsPendingCannotRestartFlight() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let vertices = largeFixture()
        let snapshot = LivePointCloudSnapshot(revision: 20, vertices: vertices,
                                             confirmedPointCount: vertices.count)
        coordinator.update(snapshot: snapshot, animatesAcquisition: true, in: view)
        coordinator.update(snapshot: snapshot, animatesAcquisition: false, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertEqual(view.poseNode?.geometry?.sources(for: .vertex).first?.vectorCount, vertices.count)
        XCTAssertFalse(view.rendersContinuously)
        XCTAssertFalse(view.isPlaying)
    }

    @MainActor
    func testLatestSnapshotReplacesPendingAcquisition() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let large = largeFixture()
        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 20, vertices: large,
                                                            confirmedPointCount: large.count),
                           animatesAcquisition: true, in: view)
        let latest = fixture()
        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 21, vertices: latest,
                                                            confirmedPointCount: latest.count),
                           animatesAcquisition: true, in: view)
        await coordinator.waitForPendingUpdates()
        let geometry = try XCTUnwrap(view.poseNode?.geometry)
        let positions = try XCTUnwrap(geometry.sources(for: .vertex).first)
        XCTAssertEqual(positions.vectorCount, latest.count)
        for index in latest.indices {
            XCTAssertEqual(vector(in: positions, index: index), latest[index].position)
        }
    }

    @MainActor
    func testModeChangesDuringFinalPreparationUseLatestSelection() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let vertices = fixture() + largeFixture()
        let mesh = ScanMesh(vertices: vertices, triangleIndices: [0, 1, 2],
                            frameCount: 20, coveredAngles: [])
        let snapshot = LivePointCloudSnapshot(revision: 21, vertices: vertices,
                                             confirmedPointCount: vertices.count)
        let camera = try XCTUnwrap(view.pointOfView)
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, displayStyle: .points, in: view)
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, displayStyle: .color, in: view)
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, displayStyle: .points, in: view)
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, displayStyle: .color, in: view)
        await coordinator.waitForPendingUpdates()
        let node = try XCTUnwrap(view.poseNode)
        let colorGeometry = try XCTUnwrap(node.geometry)
        XCTAssertEqual(colorGeometry.elements.first?.primitiveType, .triangles)
        XCTAssertTrue(view.pointOfView === camera)
        camera.position = SCNVector3(0.08, 0.03, 0.51)
        camera.eulerAngles = SCNVector3(0.1, 0.2, 0)
        let userCamera = camera.simdTransform
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, displayStyle: .points, in: view)
        await coordinator.waitForPendingUpdates()
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, displayStyle: .color, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertTrue(node.geometry === colorGeometry)
        XCTAssertEqual(camera.simdTransform, userCamera)
    }

    @MainActor
    func testCompletedResultsCenterIndependentlyOfCapturePositionAndAngle() async throws {
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
            await coordinator.waitForPendingUpdates()
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
            await coordinator.waitForPendingUpdates()
            XCTAssertEqual(node.simdTransform, capturedTransform, "Keep processing stable until the final data arrives.")
            coordinator.update(snapshot: scan, poseStore: store, surfaceMesh: mesh, in: view)
            await coordinator.waitForPendingUpdates()
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
    func testRecenteringPreservesScanSizeWhenResultControlsReduceViewport() async throws {
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
            await coordinator.waitForPendingUpdates()
            pose.columns.3 = SIMD4(0.16, 0.02, -0.34, 1)
            store.update(faceToCamera: pose)
            view.applyLatestFacePose()
            let node = try XCTUnwrap(view.poseNode)
            let captureSize = projectedSize(vertices: vertices, node: node, in: view)
            coordinator.update(snapshot: scan, poseStore: store, in: view)
            await coordinator.waitForPendingUpdates()
            if resizeBeforeResult {
                view.frame.size.height = 410
                view.layoutIfNeeded()
            }
            coordinator.update(snapshot: scan, poseStore: store, surfaceMesh: mesh, in: view)
            await coordinator.waitForPendingUpdates()
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
    func testResultArrivingBeforeFirstLayoutRetainsCaptureScale() async throws {
        let vertices = fixture()
        let mesh = ScanMesh(vertices: vertices, triangleIndices: [0, 1, 2],
                            frameCount: 5, coveredAngles: [])
        let scan = LivePointCloudSnapshot(revision: 6, vertices: vertices, confirmedPointCount: 3)
        let (capture, captureCoordinator) = renderer()
        defer { captureCoordinator.stopAnimations() }
        captureCoordinator.update(snapshot: scan, in: capture)
        await captureCoordinator.waitForPendingUpdates()
        let captureNode = try XCTUnwrap(capture.poseNode)
        let captureSize = projectedSize(vertices: vertices, node: captureNode, in: capture)

        let result = LivePointCloudSceneView(frame: .zero)
        let resultCoordinator = LivePointCloudView.Coordinator()
        defer { resultCoordinator.stopAnimations() }
        resultCoordinator.install(in: result)
        resultCoordinator.update(snapshot: scan, surfaceMesh: mesh, in: result)
        await resultCoordinator.waitForPendingUpdates()
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
    func testFinalMeshArrivingAfterProcessingCentersOnceThenPreservesUserView() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let partial = LivePointCloudSnapshot(revision: 3, vertices: [fixture()[0]], confirmedPointCount: 1)
        coordinator.update(snapshot: partial, animatesAcquisition: true, in: view)
        await coordinator.waitForPendingUpdates()
        coordinator.update(snapshot: partial, in: view)
        await coordinator.waitForPendingUpdates()
        let camera = try XCTUnwrap(view.pointOfView)
        let processingCamera = camera.simdTransform
        let vertices = fixture().map {
            ScanVertex(position: $0.position * 2 + SIMD3(0.055, 0.04, -0.02), color: $0.color)
        }
        let mesh = ScanMesh(vertices: vertices, triangleIndices: [0, 1, 2],
                            frameCount: 9, coveredAngles: [])
        coordinator.update(snapshot: partial, surfaceMesh: mesh, in: view)
        await coordinator.waitForPendingUpdates()
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
        await coordinator.waitForPendingUpdates()
        coordinator.update(snapshot: final, surfaceMesh: mesh, displayStyle: .points, in: view)
        await coordinator.waitForPendingUpdates()
        coordinator.update(snapshot: final, surfaceMesh: mesh, displayStyle: .points, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertEqual(camera.simdTransform, userCamera)
        XCTAssertEqual(node.simdTransform, centeredTransform)
    }

    @MainActor
    func testNewScanReturnsFromCenteredResultToLivePoseFraming() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        let mesh = ScanMesh(vertices: fixture(), triangleIndices: [0, 1, 2],
                            frameCount: 5, coveredAngles: [])
        let snapshot = LivePointCloudSnapshot(revision: 6, vertices: mesh.vertices, confirmedPointCount: 3)
        coordinator.update(snapshot: snapshot, surfaceMesh: mesh, in: view)
        await coordinator.waitForPendingUpdates()
        let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "livePointCloud", recursively: false))
        XCTAssertNotEqual(node.simdTransform, matrix_identity_float4x4)
        let store = LiveFacePoseStore()
        var pose = simd_float4x4(simd_quatf(angle: 0.25, axis: SIMD3(0, 1, 0)))
        pose.columns.3 = SIMD4(0.12, 0.02, -0.42, 1)
        store.update(faceToCamera: pose)
        coordinator.update(snapshot: snapshot, poseStore: store, followsFacePose: true,
                           animatesAcquisition: true, in: view)
        await coordinator.waitForPendingUpdates()
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
        await coordinator.waitForPendingUpdates()
        let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "livePointCloud", recursively: false))
        let firstGeometry = try XCTUnwrap(node.geometry)
        let birth = try birthTime(in: firstGeometry, index: 0)
        XCTAssertGreaterThanOrEqual(birth, 0)
        XCTAssertEqual((node.geometry?.firstMaterial?.value(forKey: "pointFlightEnabled") as? NSNumber)?.floatValue, 1)
        coordinator.update(snapshot: first, animatesAcquisition: true, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertTrue(node.geometry === firstGeometry)
        try await Task.sleep(for: .milliseconds(30))
        let next = LivePointCloudSnapshot(revision: 2, vertices: vertices, confirmedPointCount: 3)
        coordinator.update(snapshot: next, animatesAcquisition: true, in: view)
        await coordinator.waitForPendingUpdates()
        let updated = try XCTUnwrap(node.geometry)
        XCTAssertEqual(try birthTime(in: updated, index: 0), birth)
        XCTAssertGreaterThan(try birthTime(in: updated, index: 1), birth)
        let cameraTransform = view.pointOfView?.simdTransform
        coordinator.update(snapshot: next, animatesAcquisition: false, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertEqual((updated.firstMaterial?.value(forKey: "pointFlightEnabled") as? NSNumber)?.floatValue, 0)
        XCTAssertFalse(view.rendersContinuously)
        XCTAssertFalse(view.isPlaying)
        XCTAssertTrue(node.geometry === updated)
        XCTAssertEqual(view.pointOfView?.simdTransform, cameraTransform)
        coordinator.update(snapshot: next, animatesAcquisition: true, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertGreaterThan(try birthTime(in: XCTUnwrap(node.geometry), index: 0), birth)
        coordinator.update(snapshot: nil, animatesAcquisition: true, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertNil(node.geometry)
        XCTAssertFalse(view.rendersContinuously)
        coordinator.update(snapshot: first, animatesAcquisition: true, in: view)
        await coordinator.waitForPendingUpdates()
        XCTAssertGreaterThan(try birthTime(in: XCTUnwrap(node.geometry), index: 0), birth)
    }

    @MainActor
    func testFlightEndsItsRenderLoopWithoutMoreSnapshots() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 1, vertices: fixture(),
                                                            confirmedPointCount: 3),
                           animatesAcquisition: true, in: view)
        await coordinator.waitForPendingUpdates()
        let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "livePointCloud", recursively: false))
        XCTAssertEqual((node.geometry?.firstMaterial?.value(forKey: "pointFlightEnabled") as? NSNumber)?.floatValue, 1)
        try await Task.sleep(for: .seconds(PointCloudFlight.duration + 0.15))
        XCTAssertEqual((node.geometry?.firstMaterial?.value(forKey: "pointFlightEnabled") as? NSNumber)?.floatValue, 0)
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
        await coordinator.waitForPendingUpdates()
        try await Task.sleep(for: .milliseconds(500))
        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 2, vertices: vertices,
                                                            confirmedPointCount: 3),
                           animatesAcquisition: true, in: view)
        await coordinator.waitForPendingUpdates()
        try await Task.sleep(for: .milliseconds(400))
        let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "livePointCloud", recursively: false))
        XCTAssertEqual((node.geometry?.firstMaterial?.value(forKey: "pointFlightEnabled") as? NSNumber)?.floatValue, 1,
                       "The old deadline must not stop newly acquired particles.")
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertEqual((node.geometry?.firstMaterial?.value(forKey: "pointFlightEnabled") as? NSNumber)?.floatValue, 0)
        XCTAssertFalse(view.rendersContinuously)
        XCTAssertFalse(view.isPlaying)
    }

    @MainActor
    func testGPUArcsMoveThenReturnExactlyToMeasuredGeometry() async throws {
        let (view, coordinator) = renderer()
        defer { coordinator.stopAnimations() }
        view.pointOfView?.camera?.usesOrthographicProjection = true
        view.pointOfView?.camera?.orthographicScale = 0.3
        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 1, vertices: fixture(),
                                                            confirmedPointCount: 3),
                           animatesAcquisition: true, in: view)
        await coordinator.waitForPendingUpdates()
        let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "livePointCloud", recursively: false))
        let material = try XCTUnwrap(node.geometry?.firstMaterial)
        let birth = try birthTime(in: XCTUnwrap(node.geometry), index: 0)
        material.setValue(Float(0), forKey: "pointAcquisitionActivity")
        material.setValue(birth + 0.2, forKey: "pointFlightTime")
        let flying = try XCTUnwrap(view.snapshot().cgImage?.dataProvider?.data) as Data
        material.setValue(birth + Float(PointCloudFlight.duration), forKey: "pointFlightTime")
        let arrived = try XCTUnwrap(view.snapshot().cgImage?.dataProvider?.data) as Data
        XCTAssertNotEqual(flying, arrived, "Short arcs must visibly move new points in X/Y as well as depth.")
        material.setValue(Float(0), forKey: "pointAcquisitionActivity")
        material.setValue(Float(0), forKey: "pointFlightEnabled")
        let staticResult = try XCTUnwrap(view.snapshot().cgImage?.dataProvider?.data) as Data
        XCTAssertEqual(arrived, staticResult, "The last arc frame must equal the exact static measured geometry.")
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

    private func largeFixture() -> [ScanVertex] {
        (0..<24_000).map { index in
            ScanVertex(position: SIMD3(Float(index % 160) * 0.001 - 0.08,
                                       Float(index / 160) * 0.001 - 0.075, 0.01),
                       color: SIMD3(0.3, 0.5, 0.7))
        }
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
            let value = $0.loadUnaligned(fromByteOffset: source.dataOffset + index * source.dataStride, as: Float.self)
            let presented = (geometry.firstMaterial?.value(forKey: "pointFlightPresentedTime") as? NSNumber)?.floatValue ?? 0
            return value < 0 ? presented - value - 1 : value
        }
    }
}

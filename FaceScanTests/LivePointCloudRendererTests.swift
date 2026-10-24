import SceneKit
import UIKit
import XCTest
import simd
@testable import FaceScan

final class LivePointCloudRendererTests: XCTestCase {
    @MainActor
    func testPausedRendererOrbitsZoomsAndRedrawsAfterScanningStops() async throws {
        let previousWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let window = previousWindow?.windowScene.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let host = UIViewController()
        let view = LivePointCloudSceneView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
        view.isPlaying = false
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 30
        let renderObserver = PointCloudRenderObserver()
        view.delegate = renderObserver
        host.view.addSubview(view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            view.delegate = nil
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        let coordinator = LivePointCloudView.Coordinator()
        coordinator.install(in: view)
        let vertices = [
            ScanVertex(position: SIMD3(-0.06, 0.08, 0.01), color: SIMD3(0.9, 0.3, 0.1)),
            ScanVertex(position: SIMD3(0.04, -0.06, 0.06), color: SIMD3(0.2, 0.7, 0.9))
        ]
        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 1, vertices: vertices,
                                                            confirmedPointCount: vertices.count), in: view)
        host.view.layoutIfNeeded()
        await waitForRender(in: renderObserver, after: 0)
        XCTAssertGreaterThan(renderObserver.count, 0, "A paused viewer must draw its initial point cloud.")
        let camera = try XCTUnwrap(view.pointOfView)
        let initialTransform = camera.simdTransform
        let beforeOrbit = renderObserver.count
        let controller = view.defaultCameraController
        controller.inertiaEnabled = false
        controller.beginInteraction(CGPoint(x: 100, y: 250), withViewport: view.bounds.size)
        controller.continueInteraction(CGPoint(x: 210, y: 270), withViewport: view.bounds.size, sensitivity: 1)
        controller.endInteraction(CGPoint(x: 210, y: 270), withViewport: view.bounds.size, velocity: .zero)
        XCTAssertNotEqual(camera.simdTransform, initialTransform, "Dragging must orbit the camera even when scene playback is paused.")
        await waitForRender(in: renderObserver, after: beforeOrbit)
        XCTAssertGreaterThan(renderObserver.count, beforeOrbit,
                             "Camera interaction must request a frame without a snapshot or continuous render loop.")

        let target = controller.target
        let targetPosition = SIMD3<Float>(target.x, target.y, target.z)
        let beforeZoomDistance = simd_distance(camera.simdPosition, targetPosition)
        let beforeZoom = renderObserver.count
        controller.dolly(toTarget: 0.05)
        XCTAssertNotEqual(simd_distance(camera.simdPosition, targetPosition), beforeZoomDistance,
                          "The stopped scan must support camera zoom.")
        await waitForRender(in: renderObserver, after: beforeZoom)
        XCTAssertGreaterThan(renderObserver.count, beforeZoom)
    }

    @MainActor
    private func waitForRender(in observer: PointCloudRenderObserver, after count: Int) async {
        for _ in 0..<40 {
            if observer.count > count { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func testGeometryContainsOnlyPointsWithPackedXYZAndCapturedRGB() throws {
        let vertices = [
            ScanVertex(position: SIMD3(-0.085, 0.12, -0.04), color: SIMD3(0.8, 0.4, 0.2)),
            ScanVertex(position: SIMD3(0.075, -0.10, 0.06), color: SIMD3(0.1, 0.3, 0.9))
        ]
        let geometry = try XCTUnwrap(LivePointGeometryBuilder.makeGeometry(vertices: vertices))
        XCTAssertTrue(geometry.sources(for: .normal).isEmpty)
        XCTAssertEqual(geometry.elements.count, 1)
        let points = try XCTUnwrap(geometry.elements.first)
        XCTAssertEqual(points.primitiveType, .point)
        XCTAssertEqual(points.primitiveCount, vertices.count)
        XCTAssertEqual(points.bytesPerIndex, MemoryLayout<UInt32>.size)
        let indices = points.data.withUnsafeBytes { bytes in
            (0..<points.primitiveCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
        }
        XCTAssertEqual(indices, [0, 1])
        XCTAssertGreaterThanOrEqual(points.minimumPointScreenSpaceRadius, 1.3)
        XCTAssertLessThanOrEqual(points.maximumPointScreenSpaceRadius, 2)

        let positions = try XCTUnwrap(geometry.sources(for: .vertex).first)
        let colors = try XCTUnwrap(geometry.sources(for: .color).first)
        for source in [positions, colors] {
            XCTAssertEqual(source.vectorCount, vertices.count)
            XCTAssertTrue(source.usesFloatComponents)
            XCTAssertEqual(source.componentsPerVector, 3)
            XCTAssertEqual(source.bytesPerComponent, 4)
            XCTAssertEqual(source.dataStride, 24)
        }
        XCTAssertEqual(positions.dataOffset, 0)
        XCTAssertEqual(colors.dataOffset, 12)
        for (index, vertex) in vertices.enumerated() {
            XCTAssertEqual(vector(in: positions, at: index), vertex.position)
            XCTAssertEqual(vector(in: colors, at: index), vertex.color)
        }
        XCTAssertEqual(geometry.firstMaterial?.lightingModel, .constant)
    }

    func testInvalidSamplesAreDroppedWithoutLeavingHolesInPointIndices() throws {
        let color = SIMD3<Float>(0.4, 0.5, 0.6)
        let good = ScanVertex(position: SIMD3(0.02, 0.03, 0.04), color: color)
        let invalid = [
            ScanVertex(position: SIMD3(.nan, 0, 0), color: color),
            ScanVertex(position: SIMD3(0, .infinity, 0), color: color),
            ScanVertex(position: SIMD3(0, 0, -Float.infinity), color: color),
            ScanVertex(position: SIMD3(Float.greatestFiniteMagnitude, 0, 0), color: color),
            ScanVertex(position: .zero, color: SIMD3(.nan, 0, 0)),
            ScanVertex(position: .zero, color: SIMD3(0, .infinity, 0)),
            ScanVertex(position: .zero, color: SIMD3(1.1, 0, 0)),
            ScanVertex(position: .zero, color: SIMD3(0, -0.1, 0))
        ]
        let geometry = try XCTUnwrap(LivePointGeometryBuilder.makeGeometry(vertices: invalid + [good]))
        let points = try XCTUnwrap(geometry.elements.first)
        XCTAssertEqual(points.primitiveCount, 1)
        XCTAssertEqual(points.data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 0)
        let positions = try XCTUnwrap(geometry.sources(for: .vertex).first)
        XCTAssertEqual(positions.vectorCount, 1)
        XCTAssertEqual(vector(in: positions, at: 0), good.position)
        XCTAssertNil(LivePointGeometryBuilder.makeGeometry(vertices: invalid))
        XCTAssertNil(LivePointGeometryBuilder.makeGeometry(vertices: []))
    }

    @MainActor
    func testNewRevisionsPreserveCameraAndDuplicateRevisionReusesGeometry() throws {
        let view = LivePointCloudSceneView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
        let coordinator = LivePointCloudView.Coordinator()
        coordinator.install(in: view)
        let vertex = ScanVertex(position: .zero, color: SIMD3(0.4, 0.5, 0.6))
        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 1, vertices: [vertex],
                                                            confirmedPointCount: 1), in: view)
        let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "livePointCloud", recursively: false))
        let firstGeometry = try XCTUnwrap(node.geometry)
        let camera = try XCTUnwrap(view.pointOfView)
        camera.position = SCNVector3(0.22, 0.11, 0.49)
        camera.eulerAngles = SCNVector3(0.1, 0.3, -0.05)
        let userCameraTransform = camera.simdTransform

        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 1, vertices: [vertex, vertex],
                                                            confirmedPointCount: 2), in: view)
        XCTAssertTrue(node.geometry === firstGeometry, "UI-only updates must not reupload point buffers.")
        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 2, vertices: [vertex, vertex],
                                                            confirmedPointCount: 2), in: view)
        XCTAssertFalse(node.geometry === firstGeometry)
        XCTAssertEqual(node.geometry?.elements.first?.primitiveCount, 2)
        XCTAssertEqual(camera.simdTransform, userCameraTransform, "New points must not override orbit or zoom.")
        XCTAssertTrue(view.accessibilityLabel?.contains("2 个点") == true)

        coordinator.update(snapshot: nil, in: view)
        XCTAssertNil(node.geometry)
        XCTAssertNotEqual(camera.simdTransform, userCameraTransform, "Starting a new scan resets the camera once.")
        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 1, vertices: [vertex],
                                                            confirmedPointCount: 1), in: view)
        XCTAssertEqual(node.geometry?.elements.first?.primitiveCount, 1,
                       "Reusing a revision after clearing must still display the new scan.")
    }

    @MainActor
    func testHeadPoseMovesExistingPointsAndFreezesWhenScanningStops() throws {
        let view = LivePointCloudSceneView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
        let coordinator = LivePointCloudView.Coordinator()
        coordinator.install(in: view)
        let store = LiveFacePoseStore()
        var faceToCamera = matrix_identity_float4x4
        faceToCamera.columns.3.z = -0.4
        store.update(faceToCamera: faceToCamera)
        let vertex = ScanVertex(position: SIMD3(0.04, 0, 0), color: SIMD3(0.4, 0.5, 0.6))
        let snapshot = LivePointCloudSnapshot(revision: 1, vertices: [vertex], confirmedPointCount: 1)
        coordinator.update(snapshot: snapshot, poseStore: store, followsFacePose: true, in: view)
        let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "livePointCloud", recursively: false))
        let geometry = try XCTUnwrap(node.geometry)
        let camera = try XCTUnwrap(view.pointOfView)
        let cameraTransform = camera.simdTransform
        XCTAssertFalse(view.allowsCameraControl)

        faceToCamera = simd_float4x4(simd_quatf(angle: 0.4, axis: SIMD3(0, 1, 0)))
        faceToCamera.columns.3 = SIMD4(0.02, 0.01, -0.38, 1)
        store.update(faceToCamera: faceToCamera)
        view.applyLatestFacePose()
        let trackedTransform = try XCTUnwrap(store.latestPose).transform
        XCTAssertEqual(node.simdTransform, trackedTransform)
        XCTAssertTrue(node.geometry === geometry, "Head tracking must only transform the existing GPU points.")
        XCTAssertEqual(camera.simdTransform, cameraTransform)

        coordinator.update(snapshot: snapshot, poseStore: store, followsFacePose: false, in: view)
        XCTAssertTrue(view.allowsCameraControl)
        XCTAssertEqual(node.simdTransform, trackedTransform, "Stopping must keep the last displayed angle.")
        store.update(faceToCamera: matrix_identity_float4x4)
        view.applyLatestFacePose()
        XCTAssertEqual(node.simdTransform, trackedTransform, "A finished scan must ignore new camera poses.")
        XCTAssertTrue(node.geometry === geometry)
        camera.position = SCNVector3(0.25, 0.1, 0.5)
        let userCameraTransform = camera.simdTransform
        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 2, vertices: [vertex, vertex],
                                                            confirmedPointCount: 2),
                           poseStore: store, followsFacePose: false, in: view)
        XCTAssertEqual(node.simdTransform, trackedTransform)
        XCTAssertEqual(camera.simdTransform, userCameraTransform)
    }

    @MainActor
    func testInitialFramingIncludesExpandedFaceAndIsIndependentOfFirstPoint() throws {
        let view = LivePointCloudSceneView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
        let coordinator = LivePointCloudView.Coordinator()
        coordinator.install(in: view)
        let camera = try XCTUnwrap(view.pointOfView)
        let initialTransform = camera.simdTransform
        let cheek = ScanVertex(position: SIMD3(0.08, 0, 0), color: SIMD3(repeating: 0.5))
        coordinator.update(snapshot: LivePointCloudSnapshot(revision: 1, vertices: [cheek],
                                                            confirmedPointCount: 0), in: view)
        XCTAssertEqual(camera.simdTransform, initialTransform)
        for point: SCNVector3 in [SCNVector3(0, 0.18, 0), SCNVector3(0, -0.14, 0),
                                 SCNVector3(-0.125, 0, -0.1), SCNVector3(0.125, 0, -0.1)] {
            let projected = view.projectPoint(point)
            XCTAssertTrue((0...Float(view.bounds.width)).contains(projected.x), "Ear-front ROI must fit horizontally.")
            XCTAssertTrue((0...Float(view.bounds.height)).contains(projected.y), "Forehead/chin ROI must fit vertically.")
            XCTAssertTrue((0...1).contains(projected.z))
        }
    }

    private func vector(in source: SCNGeometrySource, at index: Int) -> SIMD3<Float> {
        source.data.withUnsafeBytes { bytes in
            let offset = source.dataOffset + index * source.dataStride
            return SIMD3(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self),
                         bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                         bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self))
        }
    }
}

private final class PointCloudRenderObserver: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var renderedFrames = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return renderedFrames
    }

    func renderer(_ renderer: any SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        lock.lock()
        renderedFrames += 1
        lock.unlock()
    }
}

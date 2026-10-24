import SceneKit
import SwiftUI
import UIKit
import simd

/// A dedicated live renderer: measured RGB points only, without surface or normal rebuilding.
/// Snapshots already use the face-local, meter-scale coordinate system (+Y up, +Z forward).
struct LivePointCloudView: UIViewRepresentable {
    let snapshot: LivePointCloudSnapshot?
    var poseStore: LiveFacePoseStore? = nil
    var followsFacePose = false
    var surfaceMesh: ScanMesh? = nil
    var displayStyle: MeshDisplayStyle = .points
    var animatesAcquisition = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = LivePointCloudSceneView()
        view.backgroundColor = ScanTheme.canvasUIColor
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        // Scene changes and camera gestures request frames. An idle scan does not need a render loop.
        view.rendersContinuously = false
        view.isPlaying = false
        view.isJitteringEnabled = false
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.isAccessibilityElement = true
        context.coordinator.install(in: view)
        context.coordinator.update(snapshot: snapshot, poseStore: poseStore,
                                   followsFacePose: followsFacePose, surfaceMesh: surfaceMesh,
                                   displayStyle: displayStyle, animatesAcquisition: animatesAcquisition,
                                   in: view)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.update(snapshot: snapshot, poseStore: poseStore,
                                   followsFacePose: followsFacePose, surfaceMesh: surfaceMesh,
                                   displayStyle: displayStyle, animatesAcquisition: animatesAcquisition,
                                   in: uiView)
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        (uiView as? LivePointCloudSceneView)?.stopPoseUpdates()
        coordinator.stopAnimations()
    }

    @MainActor
    final class Coordinator {
        private let pointNode = SCNNode()
        private let cameraNode = SCNNode()
        private var displayedContent: DisplayedContent?
        private var isFollowingFacePose = false
        private var isAcquiring = false
        private var hasPresentedResult = false
        private var flight: PointCloudFlight?

        private struct DisplayedContent: Equatable {
            let revision: Int?
            let style: MeshDisplayStyle
            let meshFrameCount: Int?
            let meshVertexCount: Int?
            let meshIndexCount: Int?
        }

        func install(in view: SCNView) {
            let scene = SCNScene()
            pointNode.name = "livePointCloud"
            scene.rootNode.addChildNode(pointNode)
            flight = PointCloudFlight(view: view)
            (view as? LivePointCloudSceneView)?.poseNode = pointNode

            let camera = SCNCamera()
            camera.fieldOfView = 38
            camera.projectionDirection = .vertical
            camera.zNear = 0.005
            camera.zFar = 5
            camera.wantsHDR = false
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)

            view.scene = scene
            view.pointOfView = cameraNode
            view.defaultCameraController.interactionMode = .orbitTurntable
            view.defaultCameraController.automaticTarget = false
            view.defaultCameraController.target = LivePointCloudSceneView.faceCenter
            view.defaultCameraController.inertiaEnabled = true
            // The capture is a facial surface, so avoid rotating into a nonexistent back of head.
            view.defaultCameraController.minimumHorizontalAngle = -85
            view.defaultCameraController.maximumHorizontalAngle = 85
            view.defaultCameraController.minimumVerticalAngle = -65
            view.defaultCameraController.maximumVerticalAngle = 65
            resetCamera(in: view)
        }

        func update(snapshot: LivePointCloudSnapshot?, poseStore: LiveFacePoseStore? = nil,
                    followsFacePose: Bool = false, surfaceMesh: ScanMesh? = nil,
                    displayStyle: MeshDisplayStyle = .points,
                    animatesAcquisition: Bool = false, in view: SCNView) {
            let isFollowing = followsFacePose && poseStore != nil
            if isFollowing, !isFollowingFacePose {
                // A new scan always starts from the camera's front view, even
                // if the previous finished scan was manually orbited.
                pointNode.simdTransform = matrix_identity_float4x4
                hasPresentedResult = false
                resetCamera(in: view)
            }
            isFollowingFacePose = isFollowing
            (view as? LivePointCloudSceneView)?.configurePoseTracking(
                store: poseStore, followsFacePose: isFollowing)
            view.allowsCameraControl = !isFollowing
            if let snapshot {
                let source = snapshot.isSample ? "合成示例实时点云" : "实时扫描点云"
                let interaction = isFollowing ? "随头部移动" : "可旋转和缩放"
                view.accessibilityLabel = "\(source)，\(snapshot.pointCount) 个点，\(interaction)"
            } else {
                view.accessibilityLabel = "实时点云，等待扫描数据"
            }

            let startsAcquisition = animatesAcquisition && !isAcquiring
            let rewindsSnapshot: Bool
            if let previous = displayedContent?.revision, let revision = snapshot?.revision {
                rewindsSnapshot = revision < previous
            } else {
                rewindsSnapshot = false
            }
            if startsAcquisition || rewindsSnapshot {
                flight?.reset()
                if hasPresentedResult {
                    pointNode.simdTransform = matrix_identity_float4x4
                    resetCamera(in: view)
                }
                hasPresentedResult = false
            } else if !animatesAcquisition && isAcquiring {
                flight?.finish()
            }
            isAcquiring = animatesAcquisition
            if let surfaceMesh, !animatesAcquisition, !isFollowing, !hasPresentedResult {
                // The final mesh arrives after processing. Its display must no longer
                // inherit a camera-relative head translation or the last captured angle.
                flight?.finish()
                hasPresentedResult = (view as? LivePointCloudSceneView)?.centerCompletedResult(
                    vertices: surfaceMesh.vertices, cameraNode: cameraNode) ?? false
            }
            let content = DisplayedContent(revision: snapshot?.revision, style: displayStyle,
                meshFrameCount: surfaceMesh?.frameCount, meshVertexCount: surfaceMesh?.vertexCount,
                meshIndexCount: surfaceMesh?.triangleIndices.count)
            // UI-only updates retain GPU buffers and the user's result-view camera.
            guard content != displayedContent || startsAcquisition else { return }
            displayedContent = content
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            let vertices = surfaceMesh?.vertices ?? snapshot?.vertices ?? []
            if displayStyle == .color, let surfaceMesh, !animatesAcquisition {
                flight?.finish()
                pointNode.geometry = LivePointGeometryBuilder.makeSurfaceGeometry(mesh: surfaceMesh)
            } else if animatesAcquisition {
                pointNode.geometry = flight?.makeGeometry(vertices: vertices)
            } else {
                pointNode.geometry = LivePointGeometryBuilder.makeGeometry(vertices: vertices)
            }
            if snapshot == nil && surfaceMesh == nil {
                flight?.reset()
                hasPresentedResult = false
                pointNode.simdTransform = matrix_identity_float4x4
                resetCamera(in: view)
            }
            SCNTransaction.commit()
            view.setNeedsDisplay()
        }

        func stopAnimations() { flight?.reset() }

        private func resetCamera(in view: SCNView) {
            view.defaultCameraController.stopInertia()
            if let liveView = view as? LivePointCloudSceneView {
                liveView.prepareCaptureCamera(cameraNode)
            }
        }
    }
}

enum LivePointGeometryBuilder {
    /// Interleaved, explicitly packed Float32 RGB and XYZ; never assume SIMD3's padded stride.
    static func makeGeometry(vertices: [ScanVertex]) -> SCNGeometry? {
        var values: [Float] = []
        values.reserveCapacity(vertices.count * 6)
        for vertex in vertices {
            let p = vertex.position
            let c = vertex.color
            guard isRenderable(vertex) else { continue }
            values.append(p.x)
            values.append(p.y)
            values.append(p.z)
            values.append(c.x)
            values.append(c.y)
            values.append(c.z)
        }
        let count = values.count / 6
        guard count > 0 else { return nil }
        let data = values.withUnsafeBytes { Data($0) }
        let stride = 6 * MemoryLayout<Float>.size
        let positions = SCNGeometrySource(
            data: data, semantic: .vertex, vectorCount: count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: stride
        )
        let colors = SCNGeometrySource(
            data: data, semantic: .color, vectorCount: count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 3 * MemoryLayout<Float>.size, dataStride: stride
        )
        let points = SCNGeometryElement(indices: (0..<count).map(UInt32.init), primitiveType: .point)
        points.pointSize = 0.0014
        points.minimumPointScreenSpaceRadius = 1.4
        points.maximumPointScreenSpaceRadius = 2
        let geometry = SCNGeometry(sources: [positions, colors], elements: [points])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    static func isRenderable(_ vertex: ScanVertex) -> Bool {
        let p = vertex.position
        let c = vertex.color
        return p.x.isFinite && p.y.isFinite && p.z.isFinite
            && c.x.isFinite && c.y.isFinite && c.z.isFinite
            && abs(p.x) <= 2 && abs(p.y) <= 2 && abs(p.z) <= 2
            && (0...1).contains(c.x) && (0...1).contains(c.y) && (0...1).contains(c.z)
    }

    /// Only measured triangles are drawn. A scan without faces remains a valid colored point cloud.
    static func makeSurfaceGeometry(mesh: ScanMesh) -> SCNGeometry? {
        var remap = [Int](repeating: -1, count: mesh.vertices.count)
        var vertices: [ScanVertex] = []
        vertices.reserveCapacity(mesh.vertices.count)
        for (index, vertex) in mesh.vertices.enumerated() where isRenderable(vertex) {
            remap[index] = vertices.count
            vertices.append(vertex)
        }
        guard let points = makeGeometry(vertices: vertices) else { return nil }
        var indices: [UInt32] = []
        indices.reserveCapacity(mesh.triangleIndices.count)
        for offset in stride(from: 0, to: mesh.triangleIndices.count - mesh.triangleIndices.count % 3, by: 3) {
            let original = mesh.triangleIndices[offset..<(offset + 3)].map(Int.init)
            guard original.allSatisfy({ remap.indices.contains($0) && remap[$0] >= 0 }) else { continue }
            let a = remap[original[0]], b = remap[original[1]], c = remap[original[2]]
            guard a != b, b != c, a != c,
                  simd_length_squared(simd_cross(vertices[b].position - vertices[a].position,
                                                 vertices[c].position - vertices[a].position)) > 1e-16 else { continue }
            indices.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)])
        }
        guard !indices.isEmpty else { return points }
        let geometry = SCNGeometry(sources: points.sources,
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = points.materials
        return geometry
    }
}

/// Capture uses one fixed facial volume. Completion centers that volume without
/// changing its display scale; subsequent updates preserve the user's orbit and zoom.
final class LivePointCloudSceneView: SCNView {
    static let faceCenter = SCNVector3(0, 0.025, -0.005)
    private static let displayMagnification: Float = 1.7
    weak var fitCameraNode: SCNNode?
    weak var poseNode: SCNNode?
    var needsInitialFit = false
    private var completedCaptureCenter: SIMD3<Float>?
    private var completedCameraDepth: Float?
    private var poseStore: LiveFacePoseStore?
    private var followsFacePose = false
    private var displayedPoseRevision: UInt64?
    private var poseDisplayLink: CADisplayLink?
    private lazy var poseDisplayLinkTarget = PoseDisplayLinkTarget(view: self)

    func configurePoseTracking(store: LiveFacePoseStore?, followsFacePose: Bool) {
        if poseStore !== store { displayedPoseRevision = nil }
        let wasFollowing = self.followsFacePose
        poseStore = store
        self.followsFacePose = followsFacePose
        if followsFacePose {
            defaultCameraController.stopInertia()
            applyLatestFacePose()
        } else if wasFollowing, let poseNode {
            // Freeze the acquired angle on stop. Orbit around the actual head
            // center so a translated scan remains easy to inspect.
            defaultCameraController.target = poseNode.convertPosition(Self.faceCenter, to: nil)
        }
        updatePoseDisplayLink()
    }

    /// Called by a small display link at camera speed, independently of the
    /// slower point snapshots and without any SwiftUI state publication.
    func applyLatestFacePose() {
        guard followsFacePose, let poseNode else { return }
        let pose = poseStore?.latestPose
        guard pose?.revision != displayedPoseRevision else { return }
        displayedPoseRevision = pose?.revision
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        poseNode.simdTransform = pose?.transform ?? matrix_identity_float4x4
        SCNTransaction.commit()
        setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePoseDisplayLink()
    }

    func stopPoseUpdates() {
        poseDisplayLink?.invalidate()
        poseDisplayLink = nil
    }

    func prepareCaptureCamera(_ cameraNode: SCNNode) {
        completedCaptureCenter = nil
        completedCameraDepth = nil
        cameraNode.camera?.zFar = 5
        fitCameraNode = cameraNode
        needsInitialFit = true
        fitCameraIfNeeded()
    }

    /// Center a display node, not its source vertices, so exported coordinates
    /// retain their original face-local metric frame.
    @discardableResult
    func centerCompletedResult(vertices: [ScanVertex], cameraNode: SCNNode) -> Bool {
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        for vertex in vertices where LivePointGeometryBuilder.isRenderable(vertex) {
            low = simd_min(low, vertex.position)
            high = simd_max(high, vertex.position)
        }
        guard low.x.isFinite, let poseNode else { return false }
        let center = (low + high) * 0.5
        let captureCenter = poseNode.simdConvertPosition(center, to: nil)
        completedCaptureCenter = captureCenter
        // Preserve perspective magnification at the face, including any forward
        // movement during capture. Lateral drift must not increase this distance.
        completedCameraDepth = needsInitialFit ? nil
            : -cameraNode.simdConvertPosition(captureCenter, from: nil).z
        defaultCameraController.stopInertia()
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        poseNode.simdTransform = matrix_identity_float4x4
        poseNode.simdPosition = -center
        fitCameraNode = cameraNode
        needsInitialFit = true
        fitCameraIfNeeded()
        SCNTransaction.commit()
        setNeedsDisplay()
        return true
    }

    private func updatePoseDisplayLink() {
        guard followsFacePose, window != nil else {
            stopPoseUpdates()
            return
        }
        guard poseDisplayLink == nil else { return }
        let link = CADisplayLink(target: poseDisplayLinkTarget,
                                 selector: #selector(PoseDisplayLinkTarget.tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        poseDisplayLink = link
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fitCameraIfNeeded()
    }

    func fitCameraIfNeeded() {
        guard needsInitialFit, bounds.width > 0, bounds.height > 0,
              let cameraNode = fitCameraNode, let camera = cameraNode.camera else { return }
        let aspect = Float(bounds.width / bounds.height)
        if completedCameraDepth == nil {
            let halfAngle: Float = 38 * .pi / 360
            // Lock the equivalent horizontal projection. Result controls reduce
            // stage height, but must not make the face smaller on screen.
            camera.projectionDirection = .horizontal
            camera.fieldOfView = CGFloat(2 * atan(tan(halfAngle) * aspect / Self.displayMagnification) * 180 / .pi)
            // Retain the capture distance; magnify only the projection so depth
            // and the completed result's scale remain consistent with scanning.
            let verticalDistance: Float = 0.15 / tan(halfAngle)
            let horizontalDistance: Float = 0.14 / (tan(halfAngle) * aspect)
            let distance = max(verticalDistance, horizontalDistance) * 1.18 + 0.10
            let center = SIMD3<Float>(0, 0.025, -0.005)
            cameraNode.simdPosition = center + SIMD3(0, 0, distance)
            cameraNode.look(at: Self.faceCenter)
        }
        if let captureCenter = completedCaptureCenter {
            // A result may arrive before the first layout (for example a sample).
            // In that case derive its depth after preparing the capture camera.
            let depth = completedCameraDepth
                ?? -cameraNode.simdConvertPosition(captureCenter, from: nil).z
            let distance = max(depth, Float(camera.zNear) * 2)
            completedCameraDepth = distance
            cameraNode.simdPosition = SIMD3(0, 0, distance)
            cameraNode.look(at: SCNVector3Zero)
            // Refresh both home-view references. SceneKit's built-in double-tap
            // reset must use the completed model's centered camera.
            pointOfView = cameraNode
            defaultCameraController.pointOfView = cameraNode
            defaultCameraController.target = SCNVector3Zero
            needsInitialFit = false
            return
        }
        pointOfView = cameraNode
        defaultCameraController.pointOfView = cameraNode
        defaultCameraController.target = Self.faceCenter
        needsInitialFit = false
    }
}

/// CADisplayLink retains its target. Keep the target's view reference weak so
/// removing the SwiftUI surface cannot retain a renderer and its point buffers.
@MainActor
private final class PoseDisplayLinkTarget: NSObject {
    weak var view: LivePointCloudSceneView?

    init(view: LivePointCloudSceneView) { self.view = view }

    @objc func tick() { view?.applyLatestFacePose() }
}

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
                                   followsFacePose: followsFacePose, in: view)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.update(snapshot: snapshot, poseStore: poseStore,
                                   followsFacePose: followsFacePose, in: uiView)
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        (uiView as? LivePointCloudSceneView)?.stopPoseUpdates()
    }

    @MainActor
    final class Coordinator {
        private let pointNode = SCNNode()
        private let cameraNode = SCNNode()
        private var displayedRevision: Int?
        private var isFollowingFacePose = false

        func install(in view: SCNView) {
            let scene = SCNScene()
            pointNode.name = "livePointCloud"
            scene.rootNode.addChildNode(pointNode)
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
                    followsFacePose: Bool = false, in view: SCNView) {
            let isFollowing = followsFacePose && poseStore != nil
            if isFollowing, !isFollowingFacePose {
                // A new scan always starts from the camera's front view, even
                // if the previous finished scan was manually orbited.
                pointNode.simdTransform = matrix_identity_float4x4
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

            // SwiftUI also updates for hints, counters, and camera frames. Only upload a new revision.
            guard snapshot?.revision != displayedRevision else { return }
            displayedRevision = snapshot?.revision
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            pointNode.geometry = snapshot.flatMap { LivePointGeometryBuilder.makeGeometry(vertices: $0.vertices) }
            if snapshot == nil {
                pointNode.simdTransform = matrix_identity_float4x4
                resetCamera(in: view)
            }
            SCNTransaction.commit()
            view.setNeedsDisplay()
        }

        private func resetCamera(in view: SCNView) {
            view.defaultCameraController.stopInertia()
            if let liveView = view as? LivePointCloudSceneView {
                liveView.fitCameraNode = cameraNode
                liveView.needsInitialFit = true
                liveView.fitCameraIfNeeded()
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
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
                  c.x.isFinite, c.y.isFinite, c.z.isFinite,
                  // A face-local observation cannot be meters away from the head origin.
                  abs(p.x) <= 2, abs(p.y) <= 2, abs(p.z) <= 2,
                  (0...1).contains(c.x), (0...1).contains(c.y), (0...1).contains(c.z) else { continue }
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
}

/// Fit one fixed facial volume after layout, then preserve orbit and zoom between snapshots.
/// In particular, a sparse first frame must not zoom into a cheek and jump out as new points arrive.
final class LivePointCloudSceneView: SCNView {
    static let faceCenter = SCNVector3(0, 0.025, -0.005)
    weak var fitCameraNode: SCNNode?
    weak var poseNode: SCNNode?
    var needsInitialFit = false
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
        let halfAngle = Float(camera.fieldOfView) * .pi / 360
        // Stable 30 cm height plus margin includes the enlarged forehead, chin, and ear-front ROI.
        let verticalDistance: Float = 0.15 / tan(halfAngle)
        let horizontalDistance: Float = 0.14 / (tan(halfAngle) * aspect)
        let distance = max(verticalDistance, horizontalDistance) * 1.18 + 0.10
        let center = SIMD3<Float>(0, 0.025, -0.005)
        cameraNode.simdPosition = center + SIMD3(0, 0, distance)
        cameraNode.look(at: Self.faceCenter)
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

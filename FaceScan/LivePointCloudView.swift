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
    /// Original and filtered geometry share this identity to keep comparison framing stable.
    var resultFramingIdentity: UUID? = nil
    var displayStyle: MeshDisplayStyle = .points
    var animatesAcquisition = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = LivePointCloudSceneView()
        view.backgroundColor = ScanTheme.canvasUIColor
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
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
                                   resultFramingIdentity: resultFramingIdentity,
                                   displayStyle: displayStyle, animatesAcquisition: animatesAcquisition,
                                   in: view)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.update(snapshot: snapshot, poseStore: poseStore,
                                   followsFacePose: followsFacePose, surfaceMesh: surfaceMesh,
                                   resultFramingIdentity: resultFramingIdentity,
                                   displayStyle: displayStyle, animatesAcquisition: animatesAcquisition,
                                   in: uiView)
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.stopAnimations()
        (uiView as? LivePointCloudSceneView)?.stopRenderUpdates()
    }

    @MainActor
    final class Coordinator {
        private let pointNode = SCNNode()
        private let cameraNode = SCNNode()
        private let pipeline = PointCloudRenderPipeline()
        private let resources = PointCloudRenderResources()
        private var requestedContent: RenderContent?
        private var renderedContent: RenderContent?
        private var preparedGeometry: (points: SCNGeometry?, surface: SCNGeometry?)?
        private var preparedCenter: SIMD3<Float>?
        private var selectedStyle: MeshDisplayStyle = .points
        private var isFollowingFacePose = false
        private var isAcquiring = false
        private var hasPresentedResult = false
        private var requestedResultFramingIdentity: UUID?
        private var flight: PointCloudFlight?

        private struct RenderContent: Equatable {
            let revision: Int?
            let meshIdentity: UUID?

            init(snapshot: LivePointCloudSnapshot?, mesh: ScanMesh?) {
                revision = mesh == nil ? snapshot?.revision : nil
                meshIdentity = mesh?.renderIdentity
            }
        }

        func install(in view: SCNView) {
            view.preferredFramesPerSecond = 60
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
                    resultFramingIdentity: UUID? = nil,
                    displayStyle: MeshDisplayStyle = .points,
                    animatesAcquisition: Bool = false, in view: SCNView) {
            let isFollowing = followsFacePose && poseStore != nil
            selectedStyle = displayStyle
            if isFollowing, !isFollowingFacePose {
                // A new scan always starts from the camera's front view, even
                // if the previous finished scan was manually orbited.
                pointNode.simdTransform = matrix_identity_float4x4
                hasPresentedResult = false
                requestedResultFramingIdentity = nil
                resetCamera(in: view)
            }
            isFollowingFacePose = isFollowing
            (view as? LivePointCloudSceneView)?.configurePoseTracking(
                store: poseStore, followsFacePose: isFollowing)
            view.allowsCameraControl = !isFollowing
            if let surfaceMesh {
                let source = surfaceMesh.isSample ? "合成示例" : "扫描结果"
                let processing = surfaceMesh.isFiltered ? "滤波后点云" : "原始点云"
                view.accessibilityLabel = "\(source)，\(processing)，\(surfaceMesh.vertexCount) 个点，可旋转和缩放"
            } else if let snapshot {
                let source = snapshot.isSample ? "合成示例实时点云" : "实时扫描点云"
                let interaction = isFollowing ? "随头部移动" : "可旋转和缩放"
                view.accessibilityLabel = "\(source)，\(snapshot.pointCount) 个点，\(interaction)"
            } else {
                view.accessibilityLabel = "实时点云，等待扫描数据"
            }

            let startsAcquisition = animatesAcquisition && !isAcquiring
            let rewindsSnapshot: Bool
            if let previous = requestedContent?.revision, let revision = snapshot?.revision {
                rewindsSnapshot = revision < previous
            } else {
                rewindsSnapshot = false
            }
            if startsAcquisition || rewindsSnapshot {
                pipeline.reset()
                flight?.reset()
                requestedContent = nil
                renderedContent = nil
                preparedGeometry = nil
                requestedResultFramingIdentity = nil
                if hasPresentedResult {
                    pointNode.simdTransform = matrix_identity_float4x4
                    resetCamera(in: view)
                }
                hasPresentedResult = false
            } else if !animatesAcquisition && isAcquiring {
                // A queued animated snapshot must never restart the flight after stop.
                pipeline.reset()
                requestedContent = nil
                flight?.finish()
            }
            isAcquiring = animatesAcquisition
            if snapshot == nil && surfaceMesh == nil {
                pipeline.reset()
                flight?.reset()
                requestedContent = nil
                renderedContent = nil
                preparedGeometry = nil
                preparedCenter = nil
                hasPresentedResult = false
                requestedResultFramingIdentity = nil
                pointNode.geometry = nil
                pointNode.simdTransform = matrix_identity_float4x4
                resetCamera(in: view)
                view.setNeedsDisplay()
                return
            }

            let content = RenderContent(snapshot: snapshot, mesh: surfaceMesh)
            let presentsResult = surfaceMesh != nil && !animatesAcquisition && !isFollowing
            if let surfaceMesh {
                let framingIdentity = resultFramingIdentity ?? surfaceMesh.renderIdentity
                if framingIdentity != requestedResultFramingIdentity {
                    hasPresentedResult = false
                }
                requestedResultFramingIdentity = framingIdentity
            }
            if content == renderedContent {
                requestedContent = content
                presentPreparedGeometry(in: view, presentsResult: presentsResult)
                return
            }
            // Style changes while data is preparing only change selectedStyle.
            guard content != requestedContent else { return }
            requestedContent = content
            let input = PointCloudRenderPipeline.Input(
                vertices: surfaceMesh?.vertices ?? snapshot?.vertices ?? [],
                triangleIndices: surfaceMesh?.triangleIndices ?? [], animates: animatesAcquisition)
            pipeline.submit(input) { [weak self, weak view] data in
                guard let self, let view, self.requestedContent == content else { return }
                self.preparedGeometry = self.resources.make(data: data)
                self.preparedCenter = data.center
                self.renderedContent = content
                SCNTransaction.begin()
                SCNTransaction.disableActions = true
                self.presentPreparedGeometry(in: view, presentsResult: presentsResult)
                if self.isAcquiring {
                    self.flight?.activate(geometry: self.pointNode.geometry, endTime: data.animationEndTime)
                }
                SCNTransaction.commit()
                view.setNeedsDisplay()
            }
        }

        func stopAnimations() {
            pipeline.reset()
            requestedContent = nil
            flight?.reset()
        }

        func waitForPendingUpdates() async { await pipeline.waitUntilIdle() }

        private func presentPreparedGeometry(in view: SCNView, presentsResult: Bool) {
            if presentsResult, !hasPresentedResult {
                flight?.finish()
                hasPresentedResult = (view as? LivePointCloudSceneView)?.centerCompletedResult(
                    center: preparedCenter, cameraNode: cameraNode) ?? false
            }
            let geometry = selectedStyle == .color && presentsResult
                ? preparedGeometry?.surface : preparedGeometry?.points
            if pointNode.geometry !== geometry {
                SCNTransaction.begin()
                SCNTransaction.disableActions = true
                pointNode.geometry = geometry
                SCNTransaction.commit()
                view.setNeedsDisplay()
            }
        }

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
    weak var fitCameraNode: SCNNode?
    weak var poseNode: SCNNode?
    var needsInitialFit = false
    private var completedCaptureCenter: SIMD3<Float>?
    private var completedCameraDepth: Float?
    private var poseStore: LiveFacePoseStore?
    private var followsFacePose = false
    private var displayedPoseRevision: UInt64?
    private weak var flightAnimation: PointCloudFlight?
    private var renderDisplayLink: CADisplayLink?
    private lazy var renderDisplayLinkTarget = RenderDisplayLinkTarget(view: self)

    var isRenderClockRunning: Bool { renderDisplayLink != nil }

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
        updateRenderClock()
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
        updateRenderClock()
    }

    func stopPoseUpdates() {
        followsFacePose = false
        poseStore = nil
        displayedPoseRevision = nil
        updateRenderClock()
    }

    func setFlightAnimation(_ flight: PointCloudFlight?) {
        flightAnimation = flight
        updateRenderClock()
    }

    func stopRenderUpdates() {
        stopPoseUpdates()
        flightAnimation?.reset()
        renderDisplayLink?.invalidate()
        renderDisplayLink = nil
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
        let center = low.x.isFinite ? (low + high) * 0.5 : nil
        return centerCompletedResult(center: center, cameraNode: cameraNode)
    }

    /// The production path supplies a center already computed on the render
    /// worker; only the small camera/node transaction remains on the main actor.
    @discardableResult
    func centerCompletedResult(center: SIMD3<Float>?, cameraNode: SCNNode) -> Bool {
        guard let center, center.x.isFinite, center.y.isFinite, center.z.isFinite,
              let poseNode else { return false }
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

    func updateRenderClock() {
        guard window != nil, followsFacePose || flightAnimation?.isActive == true else {
            renderDisplayLink?.invalidate()
            renderDisplayLink = nil
            return
        }
        guard renderDisplayLink == nil else { return }
        let link = CADisplayLink(target: renderDisplayLinkTarget,
                                 selector: #selector(RenderDisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        renderDisplayLink = link
    }

    fileprivate func updateRenderFrame(at time: TimeInterval) {
        applyLatestFacePose()
        flightAnimation?.tick(at: time)
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
            // Lock the equivalent horizontal projection. Result controls reduce
            // stage height, but must not make the face smaller on screen.
            camera.projectionDirection = .horizontal
            camera.fieldOfView = CGFloat(2 * ScanDisplayFraming.horizontalHalfAngle(aspect: aspect) * 180 / .pi)
            // Retain the capture distance; magnify only the projection so depth
            // and the completed result's scale remain consistent with scanning.
            let distance = ScanDisplayFraming.cameraDistance(aspect: aspect)
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
private final class RenderDisplayLinkTarget: NSObject {
    weak var view: LivePointCloudSceneView?

    init(view: LivePointCloudSceneView) { self.view = view }

    @objc func tick(_ link: CADisplayLink) { view?.updateRenderFrame(at: link.targetTimestamp) }
}

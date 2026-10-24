import SceneKit
import SwiftUI
import UIKit
import simd

/// A file viewer with its own camera and rendering coordinates. Imported mesh
/// positions remain untouched so their original units survive a later export.
struct PLYViewerView: UIViewRepresentable {
    let id: UUID
    let mesh: ScanMesh
    var labSettings: ScanLabSettings? = nil
    var replayToken = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = PLYPointCloudSceneView()
        view.backgroundColor = ScanTheme.canvasUIColor
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = false
        view.isPlaying = false
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.isAccessibilityElement = true
        context.coordinator.install(in: view)
        context.coordinator.update(id: id, mesh: mesh, labSettings: labSettings,
                                   replayToken: replayToken, in: view)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.update(id: id, mesh: mesh, labSettings: labSettings,
                                   replayToken: replayToken, in: uiView)
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.stopLab()
    }

    @MainActor
    final class Coordinator {
        private let pointNode = SCNNode()
        private let cameraNode = SCNNode()
        private var displayedID: UUID?
        private var labRenderer: ScanLabRenderer?
        private var labMesh: ScanMesh?
        private var labRevision = 0

        func install(in view: SCNView) {
            view.allowsCameraControl = true
            let scene = SCNScene()
            pointNode.name = "importedPLYPointCloud"
            scene.rootNode.addChildNode(pointNode)

            let camera = SCNCamera()
            camera.fieldOfView = 38
            camera.projectionDirection = .vertical
            camera.zNear = 0.001
            camera.zFar = 100
            camera.wantsHDR = false
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)

            view.scene = scene
            view.pointOfView = cameraNode
            view.defaultCameraController.interactionMode = .orbitTurntable
            view.defaultCameraController.automaticTarget = false
            view.defaultCameraController.target = SCNVector3Zero
            view.defaultCameraController.inertiaEnabled = true
        }

        func update(id: UUID, mesh: ScanMesh, labSettings: ScanLabSettings? = nil,
                    replayToken: Int = 0, in view: SCNView) {
            if let labSettings {
                if labRenderer == nil || displayedID != id {
                    stopLab()
                    pointNode.geometry = nil
                    labMesh = PLYPointGeometryBuilder.makeLabMesh(mesh: mesh)
                    labRevision += 1
                    displayedID = id
                    labRenderer = ScanLabRenderer(parent: pointNode, in: view)
                    view.defaultCameraController.stopInertia()
                    if let preview = view as? PLYPointCloudSceneView {
                        preview.fitCameraNode = cameraNode
                        preview.cloudRadius = max(labMesh?.vertices.map { simd_length($0.position) }.max() ?? 0.15, 0.02)
                        preview.needsInitialFit = true
                        preview.fitCameraIfNeeded()
                    }
                }
                labRenderer?.update(vertices: labMesh?.vertices ?? [],
                    triangleIndices: labMesh?.triangleIndices ?? [], revision: labRevision,
                    settings: labSettings, animatesAcquisition: false,
                    replayToken: replayToken, in: view)
                view.accessibilityLabel = "PLY 效果实验，\(labMesh?.vertexCount ?? 0) 个点，可旋转和缩放"
                return
            }
            if labRenderer != nil {
                stopLab()
                displayedID = nil
                labMesh = nil
                view.backgroundColor = ScanTheme.canvasUIColor
                view.showsStatistics = false
                cameraNode.camera?.usesOrthographicProjection = false
                cameraNode.camera?.wantsHDR = false
                cameraNode.camera?.bloomIntensity = 0
            }
            // Hints, export state and other SwiftUI updates must preserve the
            // camera and reuse the imported file's existing GPU buffers.
            guard displayedID != id else { return }
            displayedID = id
            let cloud = PLYPointGeometryBuilder.make(vertices: mesh.vertices)
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            pointNode.geometry = cloud?.geometry
            SCNTransaction.commit()
            view.accessibilityLabel = "PLY 点云，\(cloud?.pointCount ?? 0) 个点，可旋转和缩放"
            view.defaultCameraController.stopInertia()
            if let preview = view as? PLYPointCloudSceneView {
                preview.fitCameraNode = cameraNode
                preview.cloudRadius = cloud?.radius ?? 1
                preview.needsInitialFit = true
                preview.fitCameraIfNeeded()
            }
            view.setNeedsDisplay()
        }

        func stopLab() {
            labRenderer?.stop()
            labRenderer = nil
        }
    }
}

struct PLYPointCloudGeometry {
    let geometry: SCNGeometry
    let pointCount: Int
    let radius: Float
}

enum PLYPointGeometryBuilder {
    /// The lab's physical controls use meters. Normalize only a preview copy,
    /// retaining face/vertex correspondence even after invalid points are removed.
    static func makeLabMesh(mesh: ScanMesh) -> ScanMesh? {
        var low = SIMD3<Double>(repeating: .infinity)
        var high = SIMD3<Double>(repeating: -.infinity)
        for vertex in mesh.vertices where isRenderable(vertex) {
            low = simd_min(low, SIMD3<Double>(vertex.position))
            high = simd_max(high, SIMD3<Double>(vertex.position))
        }
        guard low.x.isFinite else { return nil }
        let center = (low + high) * 0.5
        let extent = high - low
        let largest = max(extent.x, max(extent.y, extent.z))
        let scale = largest > 0 ? 0.28 / largest : 1
        var remap = [Int](repeating: -1, count: mesh.vertices.count)
        var vertices: [ScanVertex] = []
        vertices.reserveCapacity(mesh.vertices.count)
        for (index, vertex) in mesh.vertices.enumerated() where isRenderable(vertex) {
            remap[index] = vertices.count
            vertices.append(ScanVertex(position: SIMD3<Float>((SIMD3<Double>(vertex.position) - center) * scale),
                                       color: vertex.color))
        }
        var faces: [UInt32] = []
        faces.reserveCapacity(mesh.triangleIndices.count)
        for i in stride(from: 0, to: mesh.triangleIndices.count - mesh.triangleIndices.count % 3, by: 3) {
            let triangle = mesh.triangleIndices[i..<(i + 3)].map(Int.init)
            guard triangle.allSatisfy({ $0 < remap.count && remap[$0] >= 0 }) else { continue }
            faces.append(contentsOf: triangle.map { UInt32(remap[$0]) })
        }
        return ScanMesh(vertices: vertices, triangleIndices: faces, frameCount: mesh.frameCount,
                        coveredAngles: mesh.coveredAngles, isSample: mesh.isSample)
    }

    /// Explicitly packed XYZ and RGB. Normalization applies only to this GPU
    /// buffer; a PLY may use any center or units, including very large values.
    static func make(vertices: [ScanVertex]) -> PLYPointCloudGeometry? {
        var low = SIMD3<Double>(repeating: .infinity)
        var high = SIMD3<Double>(repeating: -.infinity)
        var count = 0
        for vertex in vertices where isRenderable(vertex) {
            let p = SIMD3<Double>(vertex.position)
            low = simd_min(low, p)
            high = simd_max(high, p)
            count += 1
        }
        guard count > 0 else { return nil }
        // Double keeps subtraction finite even across both Float extremes.
        let center = (low + high) * 0.5
        let extent = high - low
        let largestExtent = max(extent.x, max(extent.y, extent.z))
        let scale = largestExtent > 0 ? 2 / largestExtent : 1
        var values: [Float] = []
        values.reserveCapacity(count * 6)
        var radiusSquared: Double = 0
        for vertex in vertices where isRenderable(vertex) {
            let p = (SIMD3<Double>(vertex.position) - center) * scale
            radiusSquared = max(radiusSquared, simd_length_squared(p))
            values.append(contentsOf: [Float(p.x), Float(p.y), Float(p.z),
                                      vertex.color.x, vertex.color.y, vertex.color.z])
        }
        let data = values.withUnsafeBytes { Data($0) }
        let stride = 6 * MemoryLayout<Float>.size
        let positions = SCNGeometrySource(
            data: data, semantic: .vertex, vectorCount: count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: stride
        )
        let colors = SCNGeometrySource(
            data: data, semantic: .color, vectorCount: count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 3 * MemoryLayout<Float>.size, dataStride: stride
        )
        let points = SCNGeometryElement(indices: (0..<count).map(UInt32.init), primitiveType: .point)
        points.pointSize = 0.006
        points.minimumPointScreenSpaceRadius = 1.3
        points.maximumPointScreenSpaceRadius = 2.2
        let geometry = SCNGeometry(sources: [positions, colors], elements: [points])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.isDoubleSided = true
        geometry.materials = [material]
        return PLYPointCloudGeometry(geometry: geometry, pointCount: count,
                                     radius: max(Float(sqrt(radiusSquared)), 0.05))
    }

    private static func isRenderable(_ vertex: ScanVertex) -> Bool {
        let p = vertex.position
        let c = vertex.color
        return p.x.isFinite && p.y.isFinite && p.z.isFinite
            && c.x.isFinite && c.y.isFinite && c.z.isFinite
            && (0...1).contains(c.x) && (0...1).contains(c.y) && (0...1).contains(c.z)
    }
}

/// A sphere fit includes the entire imported object even after it is orbited.
/// The deferred initial fit runs once layout gives us the actual aspect ratio.
final class PLYPointCloudSceneView: SCNView {
    weak var fitCameraNode: SCNNode?
    var cloudRadius: Float = 1
    var needsInitialFit = false

    override func layoutSubviews() {
        super.layoutSubviews()
        fitCameraIfNeeded()
    }

    func fitCameraIfNeeded() {
        guard needsInitialFit, bounds.width > 0, bounds.height > 0,
              let cameraNode = fitCameraNode, let camera = cameraNode.camera else { return }
        let aspect = Float(bounds.width / bounds.height)
        let verticalHalfAngle = Float(camera.fieldOfView) * .pi / 360
        let horizontalHalfAngle = atan(tan(verticalHalfAngle) * aspect)
        let limitingHalfAngle = min(verticalHalfAngle, horizontalHalfAngle)
        let distance = cloudRadius / sin(limitingHalfAngle) * 1.12
        camera.zFar = Double(max(distance + cloudRadius * 4, 100))
        cameraNode.simdPosition = SIMD3(0, 0, distance)
        cameraNode.look(at: SCNVector3Zero)
        pointOfView = cameraNode
        defaultCameraController.pointOfView = cameraNode
        defaultCameraController.target = SCNVector3Zero
        needsInitialFit = false
    }
}

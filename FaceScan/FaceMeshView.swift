import SceneKit
import SwiftUI
import simd

enum MeshDisplayStyle: String, CaseIterable, Identifiable {
    case color = "原始颜色"
    case clay = "灰模"
    case points = "点云"

    var id: String { rawValue }
}

/// Displays measured, face-local vertices. Color is per-vertex RGB, not a generated texture.
struct FaceMeshView: UIViewRepresentable {
    let mesh: ScanMesh
    var style: MeshDisplayStyle = .color

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = FacePreviewSceneView()
        view.backgroundColor = ScanTheme.canvasUIColor
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.isJitteringEnabled = true
        view.accessibilityLabel = mesh.isSample ? "合成示例三维人脸，可旋转和缩放" : "扫描得到的三维人脸，可旋转和缩放"
        context.coordinator.install(in: view)
        context.coordinator.update(mesh: mesh, style: style, in: view)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.update(mesh: mesh, style: style, in: uiView)
    }

    @MainActor
    final class Coordinator {
        private let faceNode = SCNNode()
        private let cameraNode = SCNNode()
        private var lastMesh: ScanMesh?
        private var geometries: [MeshDisplayStyle: SCNGeometry] = [:]
        private var displayedStyle: MeshDisplayStyle?

        func install(in view: SCNView) {
            let scene = SCNScene()
            scene.rootNode.addChildNode(faceNode)

            let camera = SCNCamera()
            camera.fieldOfView = 38
            camera.zNear = 0.001
            camera.zFar = 20
            camera.wantsHDR = false
            cameraNode.camera = camera
            scene.rootNode.addChildNode(cameraNode)

            let headLight = SCNLight()
            headLight.type = .directional
            headLight.intensity = 850
            headLight.color = UIColor(white: 1, alpha: 1)
            let headLightNode = SCNNode()
            headLightNode.light = headLight
            headLightNode.eulerAngles = SCNVector3(-0.25, -0.35, 0)
            cameraNode.addChildNode(headLightNode)

            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.intensity = 340
            ambient.color = UIColor(white: 0.92, alpha: 1)
            let ambientNode = SCNNode()
            ambientNode.light = ambient
            scene.rootNode.addChildNode(ambientNode)

            view.scene = scene
            view.pointOfView = cameraNode
            view.defaultCameraController.interactionMode = .orbitTurntable
            view.defaultCameraController.automaticTarget = false
            view.defaultCameraController.target = SCNVector3Zero
            view.defaultCameraController.inertiaEnabled = true
            // Avoid rotating to a fabricated backside: this is an open facial surface.
            view.defaultCameraController.minimumHorizontalAngle = -85
            view.defaultCameraController.maximumHorizontalAngle = 85
            view.defaultCameraController.minimumVerticalAngle = -65
            view.defaultCameraController.maximumVerticalAngle = 65
        }

        func update(mesh: ScanMesh, style: MeshDisplayStyle, in view: SCNView) {
            if !hasSameGeometry(as: mesh) {
                lastMesh = mesh
                geometries.removeAll()
                displayedStyle = nil
                buildGeometries(mesh)
                frameFace(mesh, in: view)
            }
            if displayedStyle != style {
                // Reuse the vertex buffers and cached geometry when only the UI changes.
                faceNode.geometry = geometries[style]
                displayedStyle = style
            }
            view.accessibilityLabel = mesh.isSample ? "合成示例三维人脸，可旋转和缩放" : "扫描得到的三维人脸，可旋转和缩放"
        }

        private func hasSameGeometry(as mesh: ScanMesh) -> Bool {
            guard let previous = lastMesh,
                  previous.vertices.count == mesh.vertices.count,
                  previous.triangleIndices == mesh.triangleIndices else { return false }
            return zip(previous.vertices, mesh.vertices).allSatisfy {
                $0.position == $1.position && $0.color == $1.color
            }
        }

        private func buildGeometries(_ mesh: ScanMesh) {
            guard !mesh.vertices.isEmpty else { return }
            let vertices = mesh.vertices.map(\.position)
            var normals = Array(repeating: SIMD3<Float>.zero, count: vertices.count)
            var validIndices: [UInt32] = []
            validIndices.reserveCapacity(mesh.triangleIndices.count)
            for offset in stride(from: 0, to: mesh.triangleIndices.count - 2, by: 3) {
                let indices = Array(mesh.triangleIndices[offset..<(offset + 3)])
                let a = Int(indices[0]), b = Int(indices[1]), c = Int(indices[2])
                guard a < vertices.count, b < vertices.count, c < vertices.count else { continue }
                let normal = simd_cross(vertices[b] - vertices[a], vertices[c] - vertices[a])
                guard simd_length_squared(normal) > 1e-16 else { continue }
                normals[a] += normal
                normals[b] += normal
                normals[c] += normal
                validIndices.append(contentsOf: indices)
            }
            // Both ARKit and the reconstruction use +Z toward the front of the face.
            // Normalize winding for lighting if an imported source uses the opposite order.
            let frontSign: Float = normals.reduce(Float.zero) { $0 + $1.z } < 0 ? -1 : 1
            normals = normals.map {
                simd_length_squared($0) > 1e-16 ? simd_normalize($0) * frontSign : SIMD3(0, 0, 1)
            }
            let positions = source(vertices, semantic: .vertex)
            let normalSource = source(normals, semantic: .normal)
            let colors = source(mesh.vertices.map(\.color), semantic: .color)
            let triangles = SCNGeometryElement(indices: validIndices, primitiveType: .triangles)
            let points = SCNGeometryElement(indices: (0..<vertices.count).map(UInt32.init), primitiveType: .point)
            points.pointSize = 0.0012
            points.minimumPointScreenSpaceRadius = 1.2
            points.maximumPointScreenSpaceRadius = 3

            let colorGeometry = SCNGeometry(sources: [positions, normalSource, colors], elements: [triangles])
            colorGeometry.materials = [material(for: .color)]
            geometries[.color] = colorGeometry

            let clayGeometry = SCNGeometry(sources: [positions, normalSource], elements: [triangles])
            clayGeometry.materials = [material(for: .clay)]
            geometries[.clay] = clayGeometry

            let pointGeometry = SCNGeometry(sources: [positions, colors], elements: [points])
            pointGeometry.materials = [material(for: .points)]
            geometries[.points] = pointGeometry
        }

        private func source(_ vectors: [SIMD3<Float>], semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            // SIMD3 has 16-byte alignment. Flatten explicitly to avoid assuming a 12-byte stride.
            let values = vectors.flatMap { [$0.x, $0.y, $0.z] }
            let data = values.withUnsafeBytes { Data($0) }
            return SCNGeometrySource(
                data: data, semantic: semantic, vectorCount: vectors.count,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0, dataStride: 3 * MemoryLayout<Float>.size
            )
        }

        private func material(for style: MeshDisplayStyle) -> SCNMaterial {
            let material = SCNMaterial()
            material.isDoubleSided = true
            material.cullMode = .back
            material.diffuse.contents = style == .clay ? UIColor(white: 0.72, alpha: 1) : UIColor.white
            material.specular.contents = UIColor(white: 0.08, alpha: 1)
            material.shininess = 0.12
            // The color/point modes show captured RGB as supplied; gray mode uses light to expose shape.
            material.lightingModel = style == .clay ? .blinn : .constant
            return material
        }

        private func frameFace(_ mesh: ScanMesh, in view: SCNView) {
            guard let first = mesh.vertices.first?.position else { return }
            var low = first
            var high = first
            for vertex in mesh.vertices {
                low = simd_min(low, vertex.position)
                high = simd_max(high, vertex.position)
            }
            let center = (low + high) * 0.5
            faceNode.simdPosition = -center
            let extent = high - low
            if let preview = view as? FacePreviewSceneView {
                preview.fitCameraNode = cameraNode
                preview.faceExtent = extent
                preview.needsInitialFit = true
                preview.fitCameraIfNeeded()
            }
        }
    }
}

/// Fits the new mesh once layout is known. Later SwiftUI updates preserve the user's orbit/zoom.
private final class FacePreviewSceneView: SCNView {
    weak var fitCameraNode: SCNNode?
    var faceExtent = SIMD3<Float>(repeating: 0.2)
    var needsInitialFit = false

    override func layoutSubviews() {
        super.layoutSubviews()
        fitCameraIfNeeded()
    }

    func fitCameraIfNeeded() {
        guard needsInitialFit, bounds.width > 0, bounds.height > 0,
              let cameraNode = fitCameraNode, let camera = cameraNode.camera else { return }
        let aspect = Float(bounds.width / bounds.height)
        let halfAngle = Float(camera.fieldOfView) * .pi / 360
        let verticalDistance = max(faceExtent.y, 0.04) * 0.5 / tan(halfAngle)
        let horizontalDistance = max(faceExtent.x, 0.04) * 0.5 / (tan(halfAngle) * aspect)
        let distance = max(verticalDistance, horizontalDistance) * 1.22 + faceExtent.z * 0.5
        // A slight initial side view makes actual surface depth visible before
        // the first gesture; it does not transform or reshape measured vertices.
        let initialYaw = Float.pi / 12
        let fittedDistance = max(distance, 0.15)
        cameraNode.simdPosition = SIMD3(sin(initialYaw) * fittedDistance, 0,
                                       cos(initialYaw) * fittedDistance)
        cameraNode.look(at: SCNVector3Zero)
        pointOfView = cameraNode
        defaultCameraController.pointOfView = cameraNode
        defaultCameraController.target = SCNVector3Zero
        needsInitialFit = false
    }
}

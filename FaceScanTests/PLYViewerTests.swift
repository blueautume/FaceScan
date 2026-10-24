import SceneKit
import UIKit
import XCTest
import simd
@testable import FaceScan

final class PLYViewerTests: XCTestCase {
    func testFilePointCloudIsCenteredWithoutChangingOriginalUnitsOrColors() throws {
        let vertices = [
            ScanVertex(position: SIMD3(1000, -600, 3000), color: SIMD3(0.2, 0.4, 0.6)),
            ScanVertex(position: SIMD3(1200, -200, 3100), color: SIMD3(0.9, 0.1, 0.3))
        ]
        let cloud = try XCTUnwrap(PLYPointGeometryBuilder.make(vertices: vertices))
        let positions = try XCTUnwrap(cloud.geometry.sources(for: .vertex).first)
        let colors = try XCTUnwrap(cloud.geometry.sources(for: .color).first)
        XCTAssertEqual(cloud.pointCount, 2, "Millimeter-scale PLY coordinates must not be discarded as face outliers.")
        XCTAssertEqual(vector(in: positions, at: 0), SIMD3(-0.5, -1, -0.25))
        XCTAssertEqual(vector(in: positions, at: 1), SIMD3(0.5, 1, 0.25))
        XCTAssertEqual(vector(in: colors, at: 0), vertices[0].color)
        XCTAssertEqual(vector(in: colors, at: 1), vertices[1].color)
        XCTAssertEqual(vertices[0].position, SIMD3(1000, -600, 3000), "Normalization is confined to the rendering buffer.")
        XCTAssertEqual(cloud.geometry.elements.first?.primitiveType, .point)
        XCTAssertEqual(cloud.geometry.firstMaterial?.lightingModel, .constant)
    }

    func testNormalizationIsStableAcrossExtremeAndTinyPLYScales() throws {
        let color = SIMD3<Float>(repeating: 0.5)
        for scale: Float in [Float.greatestFiniteMagnitude, Float.leastNonzeroMagnitude] {
            let vertices = [ScanVertex(position: SIMD3(-scale, 0, 0), color: color),
                            ScanVertex(position: SIMD3(scale, 0, 0), color: color)]
            let cloud = try XCTUnwrap(PLYPointGeometryBuilder.make(vertices: vertices))
            let positions = try XCTUnwrap(cloud.geometry.sources(for: .vertex).first)
            XCTAssertEqual(vector(in: positions, at: 0), SIMD3(-1, 0, 0))
            XCTAssertEqual(vector(in: positions, at: 1), SIMD3(1, 0, 0))
            XCTAssertEqual(cloud.radius, 1)
        }
    }

    func testSinglePointAndInvalidPointCloudsRemainSafe() throws {
        let color = SIMD3<Float>(0.7, 0.4, 0.2)
        let invalid = [ScanVertex(position: SIMD3(.infinity, 0, 0), color: color),
                       ScanVertex(position: .zero, color: SIMD3(.nan, 0, 0))]
        XCTAssertNil(PLYPointGeometryBuilder.make(vertices: []))
        XCTAssertNil(PLYPointGeometryBuilder.make(vertices: invalid))
        let vertex = ScanVertex(position: SIMD3(3000, -2000, 4000), color: color)
        let cloud = try XCTUnwrap(PLYPointGeometryBuilder.make(vertices: invalid + [vertex]))
        let positions = try XCTUnwrap(cloud.geometry.sources(for: .vertex).first)
        XCTAssertEqual(cloud.pointCount, 1)
        XCTAssertEqual(vector(in: positions, at: 0), .zero)
        XCTAssertTrue(cloud.radius.isFinite)
        XCTAssertGreaterThan(cloud.radius, 0)
        XCTAssertEqual(cloud.geometry.elements.first?.primitiveCount, 1)
        XCTAssertEqual(cloud.geometry.elements.first?.data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 0)
    }

    @MainActor
    func testUnrelatedUIUpdatesPreserveCameraButOpeningAnotherFileResetsIt() throws {
        let view = PLYPointCloudSceneView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
        let coordinator = PLYViewerView.Coordinator()
        coordinator.install(in: view)
        let id = UUID()
        let mesh = testMesh()
        coordinator.update(id: id, mesh: mesh, in: view)
        let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: "importedPLYPointCloud", recursively: false))
        let firstGeometry = try XCTUnwrap(node.geometry)
        let camera = try XCTUnwrap(view.pointOfView)
        camera.position = SCNVector3(1.2, 0.5, 3)
        camera.eulerAngles = SCNVector3(0.1, 0.4, 0)
        let userTransform = camera.simdTransform
        coordinator.update(id: id, mesh: mesh, in: view)
        view.layoutSubviews()
        XCTAssertTrue(node.geometry === firstGeometry)
        XCTAssertEqual(camera.simdTransform, userTransform)
        coordinator.update(id: UUID(), mesh: mesh, in: view)
        XCTAssertFalse(node.geometry === firstGeometry)
        XCTAssertNotEqual(camera.simdTransform, userTransform)
        XCTAssertTrue(view.allowsCameraControl)
    }

    @MainActor
    func testFramingFitsTheEntireNormalizedCloudAndAllowsOrbitAndZoom() throws {
        let mesh = testMesh()
        let cloud = try XCTUnwrap(PLYPointGeometryBuilder.make(vertices: mesh.vertices))
        let positions = try XCTUnwrap(cloud.geometry.sources(for: .vertex).first)
        for size in [CGSize(width: 340, height: 500), CGSize(width: 700, height: 300)] {
            let view = PLYPointCloudSceneView(frame: CGRect(origin: .zero, size: size))
            let coordinator = PLYViewerView.Coordinator()
            coordinator.install(in: view)
            coordinator.update(id: UUID(), mesh: mesh, in: view)
            // projectPoint uses SceneKit's presentation camera. Render the
            // initial frame before checking the actual on-screen projection.
            _ = view.snapshot()
            for index in 0..<positions.vectorCount {
                let point = vector(in: positions, at: index)
                let screen = view.projectPoint(SCNVector3(point.x, point.y, point.z))
                XCTAssertTrue((0...Float(size.width)).contains(screen.x), "Projected \(point) to \(screen), size \(size), camera \(String(describing: view.pointOfView?.simdTransform))")
                XCTAssertTrue((0...Float(size.height)).contains(screen.y), "Projected \(point) to \(screen), size \(size)")
                XCTAssertTrue((0...1).contains(screen.z), "Projected \(point) to \(screen), size \(size)")
            }
            let camera = try XCTUnwrap(view.pointOfView)
            let initialTransform = camera.simdTransform
            let controller = view.defaultCameraController
            controller.inertiaEnabled = false
            controller.beginInteraction(CGPoint(x: 100, y: 150), withViewport: size)
            controller.continueInteraction(CGPoint(x: 240, y: 170), withViewport: size, sensitivity: 1)
            controller.endInteraction(CGPoint(x: 240, y: 170), withViewport: size, velocity: .zero)
            XCTAssertNotEqual(camera.simdTransform, initialTransform)
            let distance = simd_length(camera.simdPosition)
            controller.dolly(toTarget: 0.1)
            XCTAssertNotEqual(simd_length(camera.simdPosition), distance)
        }
    }

    private func testMesh() -> ScanMesh {
        ScanMesh(vertices: [
            ScanVertex(position: SIMD3(1000, -500, 3000), color: SIMD3(0.3, 0.6, 0.9)),
            ScanVertex(position: SIMD3(1400, 700, 3400), color: SIMD3(0.9, 0.6, 0.3))
        ], triangleIndices: [], frameCount: 0, coveredAngles: [])
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

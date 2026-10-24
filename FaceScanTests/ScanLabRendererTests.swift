import SceneKit
import UIKit
import XCTest
@testable import FaceScan

final class ScanLabRendererTests: XCTestCase {
    @MainActor
    func testDensityDoesNotApplyTwiceWhenFilterSettingsChange() async throws {
        let view = LivePointCloudSceneView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
        let coordinator = LivePointCloudView.Coordinator()
        coordinator.install(in: view)
        defer { coordinator.stopLab() }
        let vertices = (0..<100).map { index in
            ScanVertex(position: SIMD3(Float(index % 10) * 0.002, Float(index / 10) * 0.002, 0),
                       color: SIMD3(0.7, 0.5, 0.3))
        }
        let snapshot = LivePointCloudSnapshot(revision: 1, vertices: vertices, confirmedPointCount: 100)
        var settings = ScanLabSettings()
        settings.flyInEnabled = false
        settings.pointDensity = 0.5
        coordinator.update(snapshot: snapshot, labSettings: settings, in: view)
        let node = try await points(in: view)
        let first = try XCTUnwrap(node.geometry)
        XCTAssertEqual(first.sources(for: .vertex).first?.vectorCount, 100)
        XCTAssertEqual(first.elements.first?.primitiveCount, 50)
        settings.filterEnabled = true
        settings.filterStrength = 0
        coordinator.update(snapshot: snapshot, labSettings: settings, in: view)
        try await waitUntil { node.geometry !== first }
        XCTAssertEqual(node.geometry?.sources(for: .vertex).first?.vectorCount, 100)
        XCTAssertEqual(node.geometry?.elements.first?.primitiveCount, 50)
    }

    @MainActor
    func testNewPointsFlyWithoutReplayingExistingPointsAndStoppingSettles() async throws {
        let view = LivePointCloudSceneView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
        let coordinator = LivePointCloudView.Coordinator()
        coordinator.install(in: view)
        defer { coordinator.stopLab() }
        var settings = ScanLabSettings()
        settings.flyInStagger = 0
        let a = ScanVertex(position: .zero, color: SIMD3(0.8, 0.5, 0.2))
        let b = ScanVertex(position: SIMD3(0.03, 0.03, 0), color: SIMD3(0.2, 0.6, 0.9))
        let firstSnapshot = LivePointCloudSnapshot(revision: 1, vertices: [a], confirmedPointCount: 1)
        coordinator.update(snapshot: firstSnapshot, labSettings: settings,
                           animatesAcquisition: true, in: view)
        let node = try await points(in: view)
        let original = try XCTUnwrap(node.geometry)
        let firstBirth = try birth(in: original, index: 0)
        XCTAssertGreaterThanOrEqual(firstBirth, 0)
        try await Task.sleep(for: .milliseconds(25))
        let next = LivePointCloudSnapshot(revision: 2, vertices: [a, b], confirmedPointCount: 2)
        coordinator.update(snapshot: next, labSettings: settings, animatesAcquisition: true, in: view)
        try await waitUntil { node.geometry !== original }
        let updated = try XCTUnwrap(node.geometry)
        XCTAssertEqual(try birth(in: updated, index: 0), firstBirth)
        XCTAssertGreaterThan(try birth(in: updated, index: 1), firstBirth)
        coordinator.update(snapshot: next, labSettings: settings, animatesAcquisition: false, in: view)
        XCTAssertEqual((updated.firstMaterial?.value(forKey: "labFly") as? NSNumber)?.floatValue, 0)
        XCTAssertFalse(view.isPlaying)
        XCTAssertFalse(view.rendersContinuously)
    }

    @MainActor
    func testReplaySurvivesAsyncMeshRebuildAndResetCreatesNewBirths() async throws {
        let view = LivePointCloudSceneView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
        let coordinator = LivePointCloudView.Coordinator()
        coordinator.install(in: view)
        defer { coordinator.stopLab() }
        let vertices = [SIMD3<Float>(0, 0, 0), SIMD3(0.003, 0, 0), SIMD3(0, 0.003, 0)]
            .map { ScanVertex(position: $0, color: SIMD3(0.8, 0.5, 0.2)) }
        let snapshot = LivePointCloudSnapshot(revision: 1, vertices: vertices, confirmedPointCount: 3)
        var settings = ScanLabSettings()
        settings.flyInStagger = 0
        coordinator.update(snapshot: snapshot, labSettings: settings, in: view)
        let node = try await points(in: view)
        let first = try XCTUnwrap(node.geometry)
        XCTAssertLessThan(try birth(in: first, index: 0), -1)
        settings.displayMode = .hybrid
        coordinator.update(snapshot: snapshot, labSettings: settings, replayToken: 1, in: view)
        try await waitUntil { node.geometry !== first }
        XCTAssertGreaterThanOrEqual(try birth(in: XCTUnwrap(node.geometry), index: 0), 0)
        XCTAssertEqual((node.geometry?.firstMaterial?.value(forKey: "labFly") as? NSNumber)?.floatValue, 1)
        coordinator.update(snapshot: nil, labSettings: settings, in: view)
        try await waitUntil { node.geometry == nil }
        coordinator.update(snapshot: snapshot, labSettings: settings, animatesAcquisition: true, in: view)
        _ = try await points(in: view)
        XCTAssertGreaterThanOrEqual(try birth(in: XCTUnwrap(node.geometry), index: 0), 0)
    }

    @MainActor
    func testGPUShaderProducesVisiblePixelsAndLabCanReturnToOriginalRenderer() async throws {
        let view = LivePointCloudSceneView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
        let coordinator = LivePointCloudView.Coordinator()
        coordinator.install(in: view)
        defer { coordinator.stopLab() }
        var settings = ScanLabSettings()
        settings.flyInEnabled = false
        settings.showStats = false
        let vertices = Array(SampleFaceMesh.make().vertices.prefix(4_000))
        let snapshot = LivePointCloudSnapshot(revision: 1, vertices: vertices,
                                             confirmedPointCount: vertices.count, isSample: true)
        coordinator.update(snapshot: snapshot, labSettings: settings, in: view)
        let node = try await points(in: view)
        let visible = try XCTUnwrap(view.snapshot().cgImage?.dataProvider?.data) as Data
        node.isHidden = true
        let hidden = try XCTUnwrap(view.snapshot().cgImage?.dataProvider?.data) as Data
        XCTAssertNotEqual(visible, hidden, "The GPU particle shader must draw the measured geometry.")
        coordinator.update(snapshot: snapshot, in: view)
        XCTAssertNil(view.scene?.rootNode.childNode(withName: "scanLab", recursively: true))
        XCTAssertEqual(view.scene?.rootNode.childNode(withName: "livePointCloud", recursively: true)?
            .geometry?.elements.first?.primitiveCount, vertices.count)
        XCTAssertFalse(view.pointOfView?.camera?.wantsHDR ?? true)
    }

    @MainActor
    private func points(in view: SCNView) async throws -> SCNNode {
        try await waitUntil {
            view.scene?.rootNode.childNode(withName: "scanLabPoints", recursively: true)?.geometry != nil
        }
        return try XCTUnwrap(view.scene?.rootNode.childNode(withName: "scanLabPoints", recursively: true))
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Preview processing did not finish in time")
        throw NSError(domain: "ScanLabRendererTests", code: 1)
    }

    private func birth(in geometry: SCNGeometry, index: Int) throws -> Float {
        let source = try XCTUnwrap(geometry.sources(for: .texcoord).first)
        return source.data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: source.dataOffset + index * source.dataStride, as: Float.self)
        }
    }
}

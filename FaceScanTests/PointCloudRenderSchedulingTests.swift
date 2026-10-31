import SceneKit
import UIKit
import XCTest
@testable import FaceScan

final class PointCloudRenderSchedulingTests: XCTestCase {
    @MainActor
    func testLiveCoordinatorPresentsIntermediateFrameWhileNewerDataIsPending() async {
        let view = SchedulingRenderView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
        let coordinator = LivePointCloudView.Coordinator()
        coordinator.install(in: view)
        defer { coordinator.stopAnimations() }
        for count in 1...3 {
            coordinator.update(snapshot: snapshot(revision: count, count: count),
                               animatesAcquisition: true, in: view)
        }
        await coordinator.waitForPendingUpdates()
        XCTAssertTrue(view.presentedPointCounts.contains(1),
                      "A newer requested revision must not reject the valid running live frame.")
        XCTAssertTrue(view.presentedPointCounts.contains(3))
        XCTAssertFalse(view.presentedPointCounts.contains(2), "Only the latest pending snapshot is prepared.")
        XCTAssertEqual(view.presentedPointCounts.last, 3)
    }

    @MainActor
    func testAResultStillRejectsAnOlderQueuedResult() async {
        let view = SchedulingRenderView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
        let coordinator = LivePointCloudView.Coordinator()
        coordinator.install(in: view)
        defer { coordinator.stopAnimations() }
        for count in [1, 3] {
            let mesh = ScanMesh(vertices: vertices(count: count), triangleIndices: [], frameCount: count,
                                coveredAngles: [.center])
            coordinator.update(snapshot: nil, surfaceMesh: mesh, in: view)
        }
        await coordinator.waitForPendingUpdates()
        XCTAssertFalse(view.presentedPointCounts.contains(1), "A superseded result must never flash up.")
        XCTAssertEqual(view.presentedPointCounts.last, 3)
    }

    @MainActor
    func testStoppingOrRewindingAQueuedLiveFrameRejectsItsPresentation() async {
        for stops in [false, true] {
            let view = SchedulingRenderView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
            let coordinator = LivePointCloudView.Coordinator()
            coordinator.install(in: view)
            coordinator.update(snapshot: snapshot(revision: 10, count: 1),
                               animatesAcquisition: true, in: view)
            coordinator.update(snapshot: snapshot(revision: stops ? 11 : 1, count: 3),
                               animatesAcquisition: !stops, in: view)
            await coordinator.waitForPendingUpdates()
            XCTAssertFalse(view.presentedPointCounts.contains(1))
            XCTAssertEqual(view.presentedPointCounts.last, 3)
            coordinator.stopAnimations()
        }
    }

    private func snapshot(revision: Int, count: Int) -> LivePointCloudSnapshot {
        LivePointCloudSnapshot(revision: revision, vertices: vertices(count: count),
                               confirmedPointCount: count, pointIDs: (0..<count).map(UInt64.init))
    }

    private func vertices(count: Int) -> [ScanVertex] {
        (0..<count).map { ScanVertex(position: SIMD3(Float($0) * 0.01, 0, 0),
                                    color: SIMD3(repeating: 0.5)) }
    }
}

/// Observe the actual geometry installed by the coordinator, rather than only
/// the final result after the latest pending request has eventually completed.
@MainActor
private final class SchedulingRenderView: SCNView {
    private(set) var presentedPointCounts: [Int] = []

    override func setNeedsDisplay() {
        super.setNeedsDisplay()
        if let geometry = scene?.rootNode.childNode(withName: "livePointCloud", recursively: false)?.geometry,
           let count = geometry.elements.first?.primitiveCount {
            presentedPointCounts.append(count)
        }
    }
}

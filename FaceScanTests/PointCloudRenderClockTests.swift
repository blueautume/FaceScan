import SceneKit
import UIKit
import XCTest
import simd
@testable import FaceScan

final class PointCloudRenderClockTests: XCTestCase {
    @MainActor
    func testFlightFinishingKeepsPoseClockAndHeadUpdates() async throws {
        let context = try VisibleClockContext()
        defer { context.close() }
        XCTAssertEqual(context.view.preferredFramesPerSecond, 60)
        XCTAssertFalse(context.view.isRenderClockRunning)

        let store = LiveFacePoseStore()
        var pose = matrix_identity_float4x4
        pose.columns.3.z = -0.4
        store.update(faceToCamera: pose)
        context.view.configurePoseTracking(store: store, followsFacePose: true)
        XCTAssertTrue(context.view.isRenderClockRunning)

        context.flight.activate(geometry: context.geometry,
                                endTime: CACurrentMediaTime() + PointCloudFlight.duration)
        let initialFlightTime = try shaderTime(in: context.geometry)
        XCTAssertTrue(context.flight.isActive)
        XCTAssertTrue(context.view.isRenderClockRunning)
        pose = simd_float4x4(simd_quatf(angle: 0.2, axis: SIMD3(0, 1, 0)))
        pose.columns.3 = SIMD4(0.025, 0.015, -0.38, 1)
        store.update(faceToCamera: pose)
        let firstPose = try XCTUnwrap(store.latestPose).transform
        await eventually {
            context.node.simdTransform == firstPose
                && ((try? self.shaderTime(in: context.geometry)) ?? initialFlightTime) > initialFlightTime
        }
        XCTAssertEqual(context.node.simdTransform, firstPose)
        XCTAssertGreaterThan(try shaderTime(in: context.geometry), initialFlightTime,
                             "The same visible render clock must advance flight uniforms and head pose.")

        context.flight.finish()
        XCTAssertFalse(context.flight.isActive)
        XCTAssertFalse(context.view.rendersContinuously)
        XCTAssertFalse(context.view.isPlaying)
        XCTAssertTrue(context.view.isRenderClockRunning,
                      "Settling particles must not stop an active pose tracker.")
        pose.columns.3 = SIMD4(0.055, 0.025, -0.39, 1)
        store.update(faceToCamera: pose)
        let nextPose = try XCTUnwrap(store.latestPose).transform
        await eventually { context.node.simdTransform == nextPose }
        XCTAssertEqual(context.node.simdTransform, nextPose)
        context.view.stopPoseUpdates()
        XCTAssertFalse(context.view.isRenderClockRunning)
    }

    @MainActor
    func testStoppingPoseKeepsFlightClockUntilParticlesSettle() async throws {
        let context = try VisibleClockContext()
        defer { context.close() }
        let store = LiveFacePoseStore()
        var pose = matrix_identity_float4x4
        pose.columns.3.z = -0.4
        store.update(faceToCamera: pose)
        context.view.configurePoseTracking(store: store, followsFacePose: true)
        context.flight.activate(geometry: context.geometry,
                                endTime: CACurrentMediaTime() + PointCloudFlight.duration)
        let frozenTransform = context.node.simdTransform
        let initialFlightTime = try shaderTime(in: context.geometry)
        context.view.stopPoseUpdates()
        XCTAssertTrue(context.flight.isActive)
        XCTAssertTrue(context.view.isRenderClockRunning,
                      "Stopping head tracking must leave the shared clock available for flight.")
        pose.columns.3.x = 0.1
        store.update(faceToCamera: pose)
        await eventually {
            ((try? self.shaderTime(in: context.geometry)) ?? initialFlightTime) > initialFlightTime
        }
        XCTAssertGreaterThan(try shaderTime(in: context.geometry), initialFlightTime)
        XCTAssertEqual(context.node.simdTransform, frozenTransform,
                       "Flight must not add rotation or translation to the acquired head transform.")
        await eventually(timeout: 1.2) { !context.flight.isActive }
        XCTAssertFalse(context.flight.isActive)
        XCTAssertFalse(context.view.isRenderClockRunning)
        XCTAssertFalse(context.view.rendersContinuously)
        XCTAssertFalse(context.view.isPlaying)
        XCTAssertEqual(context.node.simdTransform, frozenTransform)
    }

    @MainActor
    func testRemovingViewStopsClockButOffscreenDeadlineStillSettlesFlight() async throws {
        let context = try VisibleClockContext()
        defer { context.close() }
        context.flight.activate(geometry: context.geometry, endTime: CACurrentMediaTime() + 0.08)
        XCTAssertTrue(context.view.isRenderClockRunning)
        context.view.removeFromSuperview()
        XCTAssertNil(context.view.window)
        XCTAssertFalse(context.view.isRenderClockRunning)
        XCTAssertTrue(context.flight.isActive)
        XCTAssertFalse(context.view.rendersContinuously,
                       "Removing the view must sleep GPU rendering before the finite arc deadline.")
        XCTAssertFalse(context.view.isPlaying)
        await eventually(timeout: 0.5) { !context.flight.isActive }
        XCTAssertFalse(context.flight.isActive)
        XCTAssertFalse(context.view.rendersContinuously)
        XCTAssertFalse(context.view.isPlaying)
        XCTAssertFalse(context.view.isRenderClockRunning)
        let enabled = context.geometry.firstMaterial?.value(forKey: "pointFlightEnabled") as? NSNumber
        XCTAssertEqual(enabled?.floatValue, 0)
    }

    @MainActor
    func testLiveSheenContinuesAfterArcsSettleWithoutNewSnapshots() async throws {
        let context = try VisibleClockContext()
        defer { context.close() }
        let pointCount = context.geometry.elements.first?.primitiveCount
        context.flight.activate(geometry: context.geometry, endTime: CACurrentMediaTime() + 0.06,
                                showsActivity: true)
        await eventually { !context.flight.isActive }
        XCTAssertFalse(context.flight.isActive)
        XCTAssertTrue(context.flight.needsRenderUpdates)
        XCTAssertTrue(context.view.isRenderClockRunning)
        XCTAssertTrue(context.view.rendersContinuously)
        let settledTime = try shaderTime(in: context.geometry)
        await eventually { ((try? self.shaderTime(in: context.geometry)) ?? settledTime) > settledTime }
        XCTAssertGreaterThan(try shaderTime(in: context.geometry), settledTime)
        XCTAssertEqual(context.geometry.elements.first?.primitiveCount, pointCount,
                       "Activity must not fabricate particles while the source stays still.")
        XCTAssertEqual(uniform("pointFlightEnabled", in: context.geometry), 0)
        XCTAssertEqual(uniform("pointAcquisitionActivity", in: context.geometry), 1)
        context.flight.finish()
        XCTAssertFalse(context.flight.needsRenderUpdates)
        XCTAssertFalse(context.view.isRenderClockRunning)
        XCTAssertFalse(context.view.rendersContinuously)
        XCTAssertEqual(uniform("pointAcquisitionActivity", in: context.geometry), 0)
    }

    @MainActor
    func testReducedMotionImmediatelySettlesAndDoesNotReplaySeenPoints() async throws {
        var reduced = false
        let context = try VisibleClockContext(reduceMotion: { reduced })
        defer { context.close() }
        context.flight.activate(geometry: context.geometry, endTime: CACurrentMediaTime() + 0.8,
                                showsActivity: true)
        XCTAssertTrue(context.flight.isActive)
        reduced = true
        context.flight.updateMotionPreference()
        XCTAssertFalse(context.flight.isActive)
        XCTAssertFalse(context.flight.needsRenderUpdates)
        XCTAssertEqual(uniform("pointFlightEnabled", in: context.geometry), 0)
        XCTAssertEqual(uniform("pointAcquisitionActivity", in: context.geometry), 0)
        reduced = false
        context.flight.updateMotionPreference()
        XCTAssertFalse(context.flight.isActive, "Switching the setting back must not replay old arcs.")
        XCTAssertGreaterThan(uniform("pointFlightMotionEpoch", in: context.geometry) ?? -.infinity,
                             uniform("pointFlightPresentedTime", in: context.geometry) ?? .infinity)
        XCTAssertTrue(context.flight.needsRenderUpdates, "The subtle live signal can resume independently.")
        context.flight.finish()
    }

    @MainActor
    func testReducedMotionAtStartKeepsMeasuredPointsStatic() throws {
        let context = try VisibleClockContext(reduceMotion: { true })
        defer { context.close() }
        context.flight.activate(geometry: context.geometry, endTime: CACurrentMediaTime() + 0.8,
                                showsActivity: true)
        XCTAssertFalse(context.flight.isActive)
        XCTAssertFalse(context.flight.needsRenderUpdates)
        XCTAssertFalse(context.view.rendersContinuously)
        XCTAssertEqual(uniform("pointFlightEnabled", in: context.geometry), 0)
        XCTAssertEqual(uniform("pointAcquisitionActivity", in: context.geometry), 0)
    }

    @MainActor
    func testActivitySleepsOffscreenAndResumesWithoutReplayingArcs() async throws {
        let context = try VisibleClockContext()
        defer { context.close() }
        context.flight.activate(geometry: context.geometry, endTime: CACurrentMediaTime() + 0.06,
                                showsActivity: true)
        await eventually { !context.flight.isActive }
        let host = try XCTUnwrap(context.view.superview)
        context.view.removeFromSuperview()
        XCTAssertFalse(context.view.isRenderClockRunning)
        XCTAssertFalse(context.view.rendersContinuously)
        host.addSubview(context.view)
        XCTAssertFalse(context.flight.isActive)
        XCTAssertTrue(context.view.isRenderClockRunning)
        XCTAssertTrue(context.view.rendersContinuously)
        context.flight.finish()
    }

    @MainActor
    private func uniform(_ key: String, in geometry: SCNGeometry) -> Float? {
        (geometry.firstMaterial?.value(forKey: key) as? NSNumber)?.floatValue
    }

    @MainActor
    private func shaderTime(in geometry: SCNGeometry) throws -> Float {
        try XCTUnwrap(geometry.firstMaterial?.value(forKey: "pointFlightTime") as? NSNumber).floatValue
    }

    @MainActor
    private func eventually(timeout: TimeInterval = 0.5, _ condition: () -> Bool) async {
        let deadline = CACurrentMediaTime() + timeout
        while !condition(), CACurrentMediaTime() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class VisibleClockContext {
    let view: LivePointCloudSceneView
    let node: SCNNode
    let geometry: SCNGeometry
    let flight: PointCloudFlight
    private let coordinator: LivePointCloudView.Coordinator
    private let window: UIWindow
    private let previousKeyWindow: UIWindow?

    init(reduceMotion: @escaping @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled }) throws {
        previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        window = previousKeyWindow?.windowScene.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        view = LivePointCloudSceneView(frame: CGRect(x: 0, y: 0, width: 340, height: 500))
        coordinator = LivePointCloudView.Coordinator()
        coordinator.install(in: view)
        node = try XCTUnwrap(view.poseNode)
        let data = PointCloudRenderDataBuilder().prepare(vertices: [
            ScanVertex(position: SIMD3(-0.04, 0.05, 0), color: SIMD3(0.9, 0.3, 0.1)),
            ScanVertex(position: SIMD3(0.04, 0.05, 0), color: SIMD3(0.2, 0.8, 0.3)),
            ScanVertex(position: SIMD3(0, -0.04, 0), color: SIMD3(0.2, 0.4, 0.9))
        ], animates: true, time: CACurrentMediaTime())
        geometry = try XCTUnwrap(PointCloudRenderResources().make(data: data).points)
        node.geometry = geometry
        flight = PointCloudFlight(view: view, reduceMotion: reduceMotion)
        let host = UIViewController()
        host.view.addSubview(view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
    }

    func close() {
        flight.reset()
        view.stopRenderUpdates()
        coordinator.stopAnimations()
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKeyAndVisible()
    }
}

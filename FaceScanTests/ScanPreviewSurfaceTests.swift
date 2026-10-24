import ARKit
import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import FaceScan

final class ScanPreviewSurfaceTests: XCTestCase {
    @MainActor
    func testDecoratedPointCloudStageReceivesTouchesAtModelCenter() async throws {
        let existingWindows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        let previousKeyWindow = existingWindows.first(where: \.isKeyWindow)
        let state = SurfaceState()
        state.showsPointCloud = true
        state.hasLiveStage = true
        state.showsCamera = false
        state.snapshot = LivePointCloudSnapshot(
            revision: 1,
            vertices: [ScanVertex(position: .zero, color: SIMD3(0.5, 0.6, 0.7))],
            confirmedPointCount: 1, isSample: true)
        let host = UIHostingController(rootView: SurfaceHarness(state: state)
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .overlay {
                RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.07))
                    .allowsHitTesting(false)
            })
        let window = existingWindows.first?.windowScene.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            state.session.pause()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        await settle(host: host)
        let renderer = try XCTUnwrap(descendants(of: host.view, type: LivePointCloudSceneView.self).first)
        let center = renderer.convert(CGPoint(x: renderer.bounds.midX, y: renderer.bounds.midY), to: window)
        let hit = window.hitTest(center, with: nil)
        XCTAssertTrue(renderer.allowsCameraControl)
        XCTAssertTrue(hit === renderer || hit?.isDescendant(of: renderer) == true,
                      "The decorative stage border and hidden camera must not intercept point-cloud gestures; hit \(String(describing: hit)).")
    }

    @MainActor
    func testCameraIdentitySurvivesScanStartDisplaySwitchesAndReset() async throws {
        try await exerciseSurface(runCamera: false)
    }

    @MainActor
    func testRunningTrueDepthSessionSurvivesScanLayoutTransitions() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("A running TrueDepth session requires a physical iPhone.")
        #else
        guard ARFaceTrackingConfiguration.isSupported,
              AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) != nil,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw XCTSkip("Requires TrueDepth hardware and previously granted camera permission.")
        }
        try await exerciseSurface(runCamera: true)
        #endif
    }

    @MainActor
    private func exerciseSurface(runCamera: Bool) async throws {
        let existingWindows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        let previousKeyWindow = existingWindows.first(where: \.isKeyWindow)
        if runCamera {
            // The host app prepares its own camera. Release that camera before
            // starting the independent session under test.
            for window in existingWindows {
                for camera in descendants(of: window, type: ARSCNView.self) {
                    camera.session.pause()
                }
            }
        }

        let state = SurfaceState()
        let host = UIHostingController(rootView: SurfaceHarness(state: state))
        let window: UIWindow
        if let scene = existingWindows.first?.windowScene {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            state.session.pause()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        await settle(host: host)
        let initialCameras = descendants(of: host.view, type: ARSCNView.self)
        XCTAssertEqual(initialCameras.count, 1)
        let camera = try XCTUnwrap(initialCameras.first)
        XCTAssertTrue(camera.session === state.session)

        if runCamera {
            let configuration = ARFaceTrackingConfiguration()
            configuration.maximumNumberOfTrackedFaces = 1
            state.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            let deadline = Date().addingTimeInterval(5)
            while state.session.currentFrame == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertNotNil(state.session.currentFrame, "The regression must exercise an active camera session.")
        }

        // These are the actual SwiftUI state changes which formerly destroyed
        // the full-screen ARSCNView and attached a new inset to the same session.
        for cycle in 0..<3 {
            let layouts: [(points: Bool, live: Bool, camera: Bool)] = [
                (true, true, true),   // Start: point cloud with camera inset.
                (false, true, true),  // Switch to camera with point-cloud inset.
                (true, true, true),   // Switch back to live points.
                (true, true, false),  // Hide camera for a synthetic presentation.
                (false, false, true) // Reset to full-screen camera.
            ]
            for (index, layout) in layouts.enumerated() {
                state.showsPointCloud = layout.points
                state.hasLiveStage = layout.live
                state.showsCamera = layout.camera
                state.followsFacePose = layout.live && index < 3
                state.snapshot = layout.live ? LivePointCloudSnapshot(
                    revision: cycle * layouts.count + index + 1,
                    vertices: [ScanVertex(position: .zero, color: SIMD3(0.5, 0.6, 0.7))],
                    confirmedPointCount: 1, isSample: true) : nil
                await settle(host: host)
                let cameras = descendants(of: host.view, type: ARSCNView.self)
                XCTAssertEqual(cameras.count, 1, "Every layout must retain exactly one camera renderer.")
                XCTAssertTrue(cameras.first === camera, "SwiftUI must resize the existing ARSCNView instead of recreating it.")
                XCTAssertTrue(cameras.first?.session === state.session)
                XCTAssertEqual(descendants(of: host.view, type: LivePointCloudSceneView.self).count, 1)
            }
        }
        if runCamera { XCTAssertNotNil(state.session.currentFrame) }
    }

    @MainActor
    private func settle(host: UIViewController) async {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(20))
        host.view.layoutIfNeeded()
    }

    @MainActor
    private func descendants<T: UIView>(of view: UIView, type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: $0, type: type) }
    }
}

@MainActor
private final class SurfaceState: ObservableObject {
    let session = ARSession()
    let poseStore = LiveFacePoseStore()
    @Published var snapshot: LivePointCloudSnapshot?
    @Published var showsPointCloud = false
    @Published var hasLiveStage = false
    @Published var showsCamera = true
    @Published var followsFacePose = false
}

private struct SurfaceHarness: View {
    @ObservedObject var state: SurfaceState

    var body: some View {
        ScanPreviewSurface(session: state.session, snapshot: state.snapshot,
                           showsPointCloud: state.showsPointCloud,
                           hasLiveStage: state.hasLiveStage, showsCamera: state.showsCamera,
                           poseStore: state.poseStore, followsFacePose: state.followsFacePose)
            .frame(width: 340, height: 420)
    }
}

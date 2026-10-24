import ARKit
import SceneKit
import SwiftUI

/// Keep both native renderers at fixed SwiftUI identities. Moving the camera
/// between the main stage and its inset must never attach a second ARSCNView
/// to the running session: ARKit publishes orientation changes synchronously
/// during that attachment, which can reenter SwiftUI while ARKit holds a lock.
struct ScanPreviewSurface: View {
    let session: ARSession
    let snapshot: LivePointCloudSnapshot?
    let showsPointCloud: Bool
    let hasLiveStage: Bool
    let showsCamera: Bool
    var poseStore: LiveFacePoseStore? = nil
    var followsFacePose = false
    var labSettings: ScanLabSettings? = nil
    var surfaceMesh: ScanMesh? = nil
    var animatesAcquisition = false
    var replayToken = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                LivePointCloudView(snapshot: snapshot, poseStore: poseStore,
                                   followsFacePose: followsFacePose,
                                   labSettings: labSettings, surfaceMesh: surfaceMesh,
                                   animatesAcquisition: animatesAcquisition,
                                   replayToken: replayToken)
                    .frame(width: showsPointCloud ? geometry.size.width : 130,
                           height: showsPointCloud ? geometry.size.height : 155)
                    .clipShape(RoundedRectangle(cornerRadius: showsPointCloud ? 0 : 16))
                    .position(x: showsPointCloud ? geometry.size.width / 2 : 79,
                              y: showsPointCloud ? geometry.size.height / 2 : geometry.size.height - 91.5)
                    .opacity(hasLiveStage ? 1 : 0)
                    .allowsHitTesting(hasLiveStage)
                    .accessibilityHidden(!hasLiveStage)
                    .zIndex(showsPointCloud ? 0 : 1)

                CameraPreview(session: session)
                    .frame(width: showsPointCloud ? 91 : geometry.size.width,
                           height: showsPointCloud ? 124 : geometry.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: showsPointCloud ? 14 : 0))
                    .position(x: showsPointCloud ? geometry.size.width - 58.5 : geometry.size.width / 2,
                              y: showsPointCloud ? 75 : geometry.size.height / 2)
                    .opacity(showsCamera ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(showsPointCloud ? 1 : 0)
            }
        }
        .background(ScanTheme.canvas)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.scene = SCNScene()
        view.backgroundColor = ScanTheme.canvasUIColor
        view.automaticallyUpdatesLighting = false
        view.preferredFramesPerSecond = 30
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) {
        uiView.isPlaying = false
    }
}

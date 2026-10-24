import SceneKit
import UIKit

/// Shader attributes use Float32, so keep their clock near zero even after a
/// device has been running for days. Scheduling deadlines remain Double values.
enum PointCloudAnimationTime {
    static let origin = CACurrentMediaTime()

    static func shaderTime(at absoluteTime: TimeInterval) -> Float {
        Float(absoluteTime - origin)
    }
}

/// Updates one prepared GPU animation. Point packing and birth matching belong
/// to the background render-data builder; this object only updates uniforms.
@MainActor
final class PointCloudFlight {
    static let duration: TimeInterval = 0.8
    static let distance: Float = 0.14

    private weak var view: SCNView?
    private weak var material: SCNMaterial?
    private var endTime: TimeInterval = 0
    private var completionTask: Task<Void, Never>?
    private(set) var isActive = false

    init(view: SCNView) {
        self.view = view
        (view as? LivePointCloudSceneView)?.setFlightAnimation(self)
    }

    func activate(geometry: SCNGeometry?, endTime: TimeInterval?) {
        let nextMaterial = geometry?.firstMaterial
        if material !== nextMaterial {
            material?.setValue(Float(0), forKey: "pointFlightEnabled")
        }
        material = nextMaterial
        let now = CACurrentMediaTime()
        guard let endTime, endTime.isFinite, endTime > now,
              material != nil, geometry?.sources(for: .texcoord).isEmpty == false else {
            finish()
            return
        }
        self.endTime = endTime
        isActive = true
        view?.rendersContinuously = true
        view?.isPlaying = true
        tick(at: now)
        scheduleCompletion()
        (view as? LivePointCloudSceneView)?.updateRenderClock()
    }

    func finish() {
        completionTask?.cancel()
        completionTask = nil
        isActive = false
        endTime = 0
        material?.setValue(Float(0), forKey: "pointFlightEnabled")
        view?.rendersContinuously = false
        view?.isPlaying = false
        view?.setNeedsDisplay()
        // Pose tracking can still need the shared clock after particles settle.
        (view as? LivePointCloudSceneView)?.updateRenderClock()
    }

    func reset() {
        finish()
        material = nil
    }

    private func scheduleCompletion() {
        completionTask?.cancel()
        let deadline = endTime
        let delay = max(0, deadline - CACurrentMediaTime())
        // Display links stop offscreen. The independent deadline still releases
        // continuous rendering without retaining either the flight or the view.
        completionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch { return }
            guard !Task.isCancelled, let self, self.endTime == deadline else { return }
            self.finish()
        }
    }

    func tick(at time: TimeInterval) {
        guard isActive else { return }
        guard material != nil, time < endTime else {
            finish()
            return
        }
        material?.setValue(PointCloudAnimationTime.shaderTime(at: time), forKey: "pointFlightTime")
        material?.setValue(Float(1), forKey: "pointFlightEnabled")
        view?.setNeedsDisplay()
    }

    // Birth time is a vertex attribute. Each frame updates only two uniforms;
    // X/Y and all rotations stay exactly as supplied by the measured geometry.
    static let shader = """
    #pragma arguments
    float pointFlightTime;
    float pointFlightEnabled;
    #pragma body
    float t = clamp((pointFlightTime - _geometry.texcoords[0].x) / 0.8, 0.0, 1.0);
    float remaining = 1.0 - t;
    _geometry.position.z += 0.14 * remaining * remaining * pointFlightEnabled;
    """
}

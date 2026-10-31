import SceneKit
import UIKit

/// Shared by the serial data builder and the UI/GPU presentation. Distances
/// are meters; animation never changes the measured vertex buffers.
enum PointCloudParticleStyle {
    static let revealSpread: TimeInterval = 0.22
    static let minimumDuration: TimeInterval = 0.58
    static let durationVariation: TimeInterval = 0.18
    static let maximumLifetime = revealSpread + minimumDuration + durationVariation

    static func duration(seed: Float) -> TimeInterval {
        minimumDuration + Double(seed) * durationVariation
    }
}

/// Keep Float32 shader clocks precise even after days of device uptime.
enum PointCloudAnimationTime {
    static let origin = CACurrentMediaTime()
    static func shaderTime(at absoluteTime: TimeInterval) -> Float {
        Float(absoluteTime - origin)
    }
}

/// One display clock drives short acquisition arcs and a much quieter live
/// sheen, independently of new depth frames and head poses.
@MainActor
final class PointCloudFlight {
    static let duration = PointCloudParticleStyle.maximumLifetime
    private weak var view: SCNView?
    private weak var material: SCNMaterial?
    private var endTime: TimeInterval = 0
    private var completionTask: Task<Void, Never>?
    private var motionObserver: NSObjectProtocol?
    private let reduceMotion: @MainActor () -> Bool
    private var reducedMotion: Bool
    private var activityRequested = false
    private var motionEpoch: Float = -.greatestFiniteMagnitude
    private(set) var isActive = false
    var needsRenderUpdates: Bool { isActive || (activityRequested && !reducedMotion) }

    init(view: SCNView, reduceMotion: @escaping @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled }) {
        self.view = view
        self.reduceMotion = reduceMotion
        reducedMotion = reduceMotion()
        (view as? LivePointCloudSceneView)?.setFlightAnimation(self)
        motionObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateMotionPreference() }
        }
    }

    deinit {
        completionTask?.cancel()
        if let motionObserver { NotificationCenter.default.removeObserver(motionObserver) }
    }

    /// The same UI submission time is acknowledged to the birth history.
    /// Negative attributes encode pending delays, unaffected by preparation time.
    @discardableResult
    func activate(geometry: SCNGeometry?, endTime: TimeInterval?,
                  presentedAt: TimeInterval? = nil, showsActivity: Bool = false) -> TimeInterval {
        let now = presentedAt ?? CACurrentMediaTime()
        updateMotionPreference()
        let nextMaterial = geometry?.firstMaterial
        if material !== nextMaterial { disableMaterial() }
        material = nextMaterial
        guard material != nil, geometry?.sources(for: .texcoord).isEmpty == false else {
            finish()
            return now
        }
        activityRequested = showsActivity
        material?.setValue(PointCloudAnimationTime.shaderTime(at: now), forKey: "pointFlightPresentedTime")
        material?.setValue(motionEpoch, forKey: "pointFlightMotionEpoch")
        self.endTime = endTime.flatMap { $0.isFinite ? $0 : nil } ?? 0
        isActive = !reducedMotion && self.endTime > now
        updateUniforms(at: now)
        scheduleCompletion()
        updateRenderState()
        return now
    }

    /// Explicit stop, result presentation and teardown leave exact static RGB.
    func finish() {
        activityRequested = false
        settle()
    }

    func reset() {
        finish()
        material = nil
        motionEpoch = -.greatestFiniteMagnitude
    }

    /// Offscreen activity sleeps; finite flights still expire at their deadline.
    func visibilityDidChange() { updateRenderState() }

    func updateMotionPreference() {
        let value = reduceMotion()
        guard value != reducedMotion else { return }
        reducedMotion = value
        if value {
            settle()
        } else {
            // Do not replay submitted points when Reduce Motion is disabled.
            motionEpoch = PointCloudAnimationTime.shaderTime(at: CACurrentMediaTime())
            material?.setValue(motionEpoch, forKey: "pointFlightMotionEpoch")
            updateUniforms(at: CACurrentMediaTime())
            updateRenderState()
        }
    }

    func tick(at time: TimeInterval) {
        if isActive, material == nil || time >= endTime { settle() }
        guard needsRenderUpdates else { return }
        updateUniforms(at: time)
        view?.setNeedsDisplay()
    }

    private func settle() {
        completionTask?.cancel()
        completionTask = nil
        isActive = false
        endTime = 0
        updateUniforms(at: CACurrentMediaTime())
        updateRenderState()
        // Draw the terminal undisplaced frame even without future snapshots.
        view?.setNeedsDisplay()
    }

    private func disableMaterial() {
        material?.setValue(Float(0), forKey: "pointFlightEnabled")
        material?.setValue(Float(0), forKey: "pointAcquisitionActivity")
    }

    private func updateUniforms(at time: TimeInterval) {
        material?.setValue(PointCloudAnimationTime.shaderTime(at: time), forKey: "pointFlightTime")
        material?.setValue(Float(isActive && !reducedMotion ? 1 : 0), forKey: "pointFlightEnabled")
        material?.setValue(Float(activityRequested && !reducedMotion ? 1 : 0), forKey: "pointAcquisitionActivity")
    }

    private func updateRenderState() {
        let runs = needsRenderUpdates
        let visible = view?.window != nil || !(view is LivePointCloudSceneView)
        view?.rendersContinuously = runs && visible
        view?.isPlaying = runs && visible
        (view as? LivePointCloudSceneView)?.updateRenderClock()
    }

    private func scheduleCompletion() {
        completionTask?.cancel()
        completionTask = nil
        guard isActive else { return }
        let deadline = endTime
        completionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline - CACurrentMediaTime()))) }
            catch { return }
            guard !Task.isCancelled, let self, self.endTime == deadline else { return }
            self.settle()
        }
    }

    // Short seeded arcs, staggered reveal and a soft arrival highlight. The
    // live sheen changes brightness by at most 4%, never point count/coverage.
    static let shader = """
    #pragma arguments
    float pointFlightTime;
    float pointFlightEnabled;
    float pointFlightPresentedTime;
    float pointFlightMotionEpoch;
    float pointAcquisitionActivity;
    #pragma body
    float seed = _geometry.texcoords[0].y;
    float encodedBirth = _geometry.texcoords[0].x;
    float birth = encodedBirth < 0.0 ? pointFlightPresentedTime - encodedBirth - 1.0 : encodedBirth;
    float firstPresentation = birth - seed * \(PointCloudParticleStyle.revealSpread);
    float enabled = pointFlightEnabled * step(pointFlightMotionEpoch, firstPresentation);
    float age = pointFlightTime - birth;
    float t = clamp(age / (\(PointCloudParticleStyle.minimumDuration) + seed * \(PointCloudParticleStyle.durationVariation)), 0.0, 1.0);
    float smoothArrival = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
    float remaining = 1.0 - smoothArrival;
    float2 radial = _geometry.position.xy - float2(0.0, 0.025);
    float2 outward = radial / max(length(radial), 0.001);
    float2 tangent = float2(-outward.y, outward.x) * (seed < 0.5 ? -1.0 : 1.0);
    float arc = sin(t * 3.14159265) * remaining;
    _geometry.position.xy += enabled * (outward * (0.006 + 0.006 * seed) * remaining + tangent * 0.004 * arc);
    _geometry.position.z += enabled * (0.008 + 0.006 * seed) * remaining;
    float appearance = mix(1.0, smoothstep(0.0, 0.12, age), enabled);
    float arrivalLight = enabled * sin(t * 3.14159265) * 0.12;
    float3 arrivingColor = mix(_geometry.color.rgb, float3(0.95, 0.83, 0.65), arrivalLight);
    _geometry.color.rgb = mix(float3(0.15686275, 0.13333333, 0.11372549), arrivingColor, appearance);
    float waveCenter = -0.14 + fract(pointFlightTime / 3.6) * 0.36;
    float wave = max(0.0, 1.0 - abs(_geometry.position.y - waveCenter) / 0.028);
    _geometry.color.rgb = min(float3(1.0), _geometry.color.rgb * (1.0 + pointAcquisitionActivity * 0.04 * wave * wave));
    """
}

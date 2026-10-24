import Foundation

/// Tracks genuinely observed views, independently of the number of fused frames.
/// Yaw and pitch use the camera-in-face convention from DepthReconstructor:
/// negative yaw is the left view; positive pitch is a lowered head.
struct ScanCoverageTracker: Sendable {
    static let minimumObservationsPerAngle = 4
    static let minimumPointsPerObservation = 250
    static let maximumYaw: Float = 58 * .pi / 180
    static let maximumPitch: Float = 30 * .pi / 180

    private var observationCounts: [ScanAngle: Int] = [:]
    private(set) var coveredAngles: Set<ScanAngle> = []

    var nextHint: String {
        guard let next = ScanAngle.allCases.first(where: { !coveredAngles.contains($0) }) else {
            return "视角已覆盖，可继续补扫或停止"
        }
        return next.guidance
    }

    mutating func reset() {
        observationCounts.removeAll()
        coveredAngles.removeAll()
    }

    mutating func observe(yaw: Float, pitch: Float, acceptedPoints: Int) {
        guard acceptedPoints >= Self.minimumPointsPerObservation,
              let angle = Self.angle(yaw: yaw, pitch: pitch) else { return }

        // Every observation belongs to exactly one view. Oblique views cannot
        // silently satisfy the straight-on or the two vertical-view targets.
        let count = min(observationCounts[angle, default: 0] + 1,
                        Self.minimumObservationsPerAngle)
        observationCounts[angle] = count
        if count >= Self.minimumObservationsPerAngle {
            coveredAngles.insert(angle)
        }
    }

    static func angle(yaw: Float, pitch: Float) -> ScanAngle? {
        guard yaw.isFinite, pitch.isFinite,
              abs(yaw) <= maximumYaw, abs(pitch) <= maximumPitch else { return nil }

        let frontYaw: Float = 12 * .pi / 180
        let nearYawMinimum: Float = 18 * .pi / 180
        let nearYawMaximum: Float = 30 * .pi / 180
        let farYawMinimum: Float = 33 * .pi / 180
        let verticalPitch: Float = 10 * .pi / 180

        if abs(yaw) <= frontYaw {
            if pitch >= verticalPitch { return .forehead }
            if pitch <= -verticalPitch { return .chin }
            return .center
        }
        // Large pitch plus yaw is useful reconstruction data, but it is not a
        // substitute for a level side view or a straight-on vertical view.
        guard abs(pitch) < verticalPitch else { return nil }
        if (nearYawMinimum...nearYawMaximum).contains(abs(yaw)) {
            return yaw < 0 ? .left : .right
        }
        if abs(yaw) >= farYawMinimum {
            return yaw < 0 ? .farLeft : .farRight
        }
        return nil
    }
}


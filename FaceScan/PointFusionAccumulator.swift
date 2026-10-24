import simd

/// Stores the newest valid observation of an associated surface point. Pixels
/// from the same depth frame share one running mean; a later frame replaces
/// that mean completely, so revisiting a region refreshes both shape and color.
/// `observedFrames` remains cumulative evidence for the two-frame noise filter.
///
/// Call on the serial reconstruction queue in nondecreasing frame order. The
/// association layer determines whether a measurement belongs to this point;
/// this type does not pull unrelated geometry together or change metric scale.
struct PointFusionAccumulator {
    var position: SIMD3<Float> { SIMD3<Float>(currentFramePosition) }
    var color: SIMD3<Float> { SIMD3<Float>(currentFrameColor) }
    private(set) var observedFrames = 0

    // Double precision keeps a dense frame's submillimeter running mean stable.
    private var currentFramePosition = SIMD3<Double>(repeating: 0)
    private var currentFrameColor = SIMD3<Double>(repeating: 0)
    private var currentFrameSamples = 0
    private var lastFrameNumber: Int?

    init(position: SIMD3<Float>, color: SIMD3<Float>, frameNumber: Int) {
        // A nonfailable initializer may be given an invalid first sample. Keep
        // an empty accumulator in that case; the next valid add initializes it.
        add(position: position, color: color, frameNumber: frameNumber)
    }

    /// Returns false for nonfinite input or an already completed, older frame.
    /// Rejected observations leave position, color and stability evidence intact.
    @discardableResult
    mutating func add(position: SIMD3<Float>, color: SIMD3<Float>,
                      frameNumber: Int) -> Bool {
        guard Self.isFinite(position), Self.isFinite(color),
              lastFrameNumber.map({ frameNumber >= $0 }) ?? true else {
            return false
        }

        let samplePosition = SIMD3<Double>(position)
        let sampleColor = SIMD3<Double>(simd_clamp(color, SIMD3(repeating: 0),
                                                 SIMD3(repeating: 1)))
        if frameNumber == lastFrameNumber {
            guard currentFrameSamples < Int.max else { return false }
            currentFrameSamples += 1
            currentFramePosition += (samplePosition - currentFramePosition)
                / Double(currentFrameSamples)
            currentFrameColor += (sampleColor - currentFrameColor)
                / Double(currentFrameSamples)
        } else {
            // The latest accepted frame owns this point. Historical observations
            // only establish stability; they never dilute the replacement data.
            currentFramePosition = samplePosition
            currentFrameColor = sampleColor
            currentFrameSamples = 1
            if observedFrames < Int.max { observedFrames += 1 }
            lastFrameNumber = frameNumber
        }
        return true
    }

    private static func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
}

/// Associates nearby measurements across voxel boundaries without averaging
/// unrelated surfaces. The caller supplies only indices in neighboring cells;
/// all distances here remain three-dimensional and measured in meters.
enum PointFusionNeighborhood {
    static func nearestIndex(to point: SIMD3<Float>, candidateIndices: [Int],
                             maximumDistance: Float,
                             positionAt: (Int) -> SIMD3<Float>) -> Int? {
        guard isFinite(point), maximumDistance.isFinite, maximumDistance > 0 else {
            return nil
        }
        let limit = Double(maximumDistance) * Double(maximumDistance)
        let sample = SIMD3<Double>(point)
        var nearest: Int?
        var nearestDistance = limit
        for index in candidateIndices where index >= 0 {
            let position = positionAt(index)
            guard isFinite(position) else { continue }
            let distance = simd_length_squared(SIMD3<Double>(position) - sample)
            guard distance <= nearestDistance else { continue }
            if distance < nearestDistance || nearest == nil || index < nearest! {
                nearest = index
                nearestDistance = distance
            }
        }
        return nearest
    }

    private static func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
}

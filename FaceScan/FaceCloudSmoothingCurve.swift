import Foundation

/// Maps local, detrended radial variation in meters to a fraction of the
/// existing geometric filter's displacement. Five fixed horizontal knots keep
/// the editor and processor on the same bounded, smooth interpolation.
public struct FaceCloudSmoothingCurve: Codable, Equatable, Sendable {
    public var strengths: [Double]
    public var maximumVariation: Double
    public var neighborhoodRadius: Double

    nonisolated public init(strengths: [Double] = [1, 0.85, 0.3, 0.05, 0],
                            maximumVariation: Double = 0.002,
                            neighborhoodRadius: Double = 0.004) {
        self.strengths = strengths
        self.maximumVariation = maximumVariation
        self.neighborhoodRadius = neighborhoodRadius
    }

    nonisolated public static let featurePreserving = FaceCloudSmoothingCurve()

    nonisolated public var isValid: Bool {
        strengths.count == 5 && strengths.allSatisfy { $0.isFinite && (0...1).contains($0) }
            && maximumVariation.isFinite && maximumVariation > 0
            && neighborhoodRadius.isFinite && neighborhoodRadius > 0
    }

    /// A uniform curve also applies at sparse boundaries where a local plane
    /// cannot be estimated. This makes horizontal 0%/100% curves exact controls.
    nonisolated var uniformStrength: Double? {
        guard isValid, let first = strengths.first,
              strengths.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    nonisolated public func strength(for variation: Double) -> Double {
        guard isValid else { return 0 }
        if let uniformStrength { return uniformStrength }
        guard variation.isFinite else { return 0 }
        let x = min(1, max(0, variation / maximumVariation)) * 4
        let index = min(3, Int(floor(x)))
        let t = x - Double(index)
        let weight = t * t * (3 - 2 * t)
        return strengths[index] + (strengths[index + 1] - strengths[index]) * weight
    }
}

import Foundation

/// Shared camera framing for live scans and the initial imported-face view.
enum ScanDisplayFraming {
    static let magnification: Float = 1.7
    static let nominalFaceSpan: Float = 0.23
    private static let verticalHalfAngle: Float = 38 * .pi / 360

    static func horizontalHalfAngle(aspect: Float) -> Float {
        atan(tan(verticalHalfAngle) * aspect / magnification)
    }

    static func cameraDistance(aspect: Float) -> Float {
        let verticalDistance: Float = 0.15 / tan(verticalHalfAngle)
        let horizontalDistance: Float = 0.14 / (tan(verticalHalfAngle) * aspect)
        return max(verticalDistance, horizontalDistance) * 1.18 + 0.10
    }
}

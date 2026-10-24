import Foundation
import simd

/// The scan stays in ARFaceAnchor's local coordinate system, in meters.
/// Colors are display RGB in the 0...1 range, sampled from the camera image.
struct ScanVertex: Sendable {
    var position: SIMD3<Float>
    var color: SIMD3<Float>
}

struct ScanMesh: Sendable {
    var vertices: [ScanVertex]
    var triangleIndices: [UInt32]
    var frameCount: Int
    var coveredAngles: Set<ScanAngle>
    var isSample: Bool = false

    var vertexCount: Int { vertices.count }
}

enum ScanAngle: String, CaseIterable, Sendable {
    case center, left, farLeft, right, farRight, forehead, chin

    var label: String {
        switch self {
        case .center: "正面"
        case .left: "左侧"
        case .farLeft: "左外侧"
        case .right: "右侧"
        case .farRight: "右外侧"
        case .forehead: "额头"
        case .chin: "下颌"
        }
    }

    var symbol: String {
        switch self {
        case .center: "person.fill.viewfinder"
        case .left: "arrow.turn.up.left"
        case .farLeft: "arrow.left.to.line"
        case .right: "arrow.turn.up.right"
        case .farRight: "arrow.right.to.line"
        case .forehead: "arrow.down"
        case .chin: "arrow.up"
        }
    }

    var guidance: String {
        switch self {
        case .center: "正对镜头，保持自然表情"
        case .left: "慢慢向一侧转头约 20°，停留片刻"
        case .farLeft: "继续向同一侧转头约 40°，停留片刻"
        case .right: "回到正面，再向另一侧转头约 20°"
        case .farRight: "继续向另一侧转头约 40°，停留片刻"
        case .forehead: "回到正面，轻轻低头，补扫额头"
        case .chin: "轻轻抬头，补扫下颌"
        }
    }
}

struct ScanProgress: Sendable {
    var acceptedFrames: Int
    var vertexCount: Int
    var coveredAngles: Set<ScanAngle>
    var hint: String
    var requiresRestart: Bool = false
}

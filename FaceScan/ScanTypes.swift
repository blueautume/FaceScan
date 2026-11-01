import Foundation
import simd

/// The scan stays in ARFaceAnchor's local coordinate system, in meters.
/// Colors are display RGB in the 0...1 range, sampled from the camera image.
struct ScanVertex: Sendable {
    var position: SIMD3<Float>
    var color: SIMD3<Float>
}

struct ScanMesh: Sendable {
    private(set) var renderIdentity: UUID
    var vertices: [ScanVertex] {
        didSet { renderIdentity = UUID() }
    }
    var triangleIndices: [UInt32] {
        didSet { renderIdentity = UUID() }
    }
    var frameCount: Int
    var coveredAngles: Set<ScanAngle>
    var isSample: Bool = false
    var isFiltered: Bool = false
    var filterSettings: ScanFilterSettings? = nil

    init(vertices: [ScanVertex], triangleIndices: [UInt32], frameCount: Int,
         coveredAngles: Set<ScanAngle>, isSample: Bool = false, isFiltered: Bool = false,
         filterSettings: ScanFilterSettings? = nil) {
        renderIdentity = UUID()
        self.vertices = vertices
        self.triangleIndices = triangleIndices
        self.frameCount = frameCount
        self.coveredAngles = coveredAngles
        self.isSample = isSample
        self.isFiltered = isFiltered
        self.filterSettings = filterSettings
    }

    var vertexCount: Int { vertices.count }
}

enum ScanAngle: String, CaseIterable, Sendable {
    case center, left, farLeft, right, farRight, forehead, chin

    var label: String {
        switch self {
        case .center: String(localized: "Front")
        case .left: String(localized: "Left")
        case .farLeft: String(localized: "Far Left")
        case .right: String(localized: "Right")
        case .farRight: String(localized: "Far Right")
        case .forehead: String(localized: "Forehead")
        case .chin: String(localized: "Chin")
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
        case .center: String(localized: "Face the camera and relax")
        case .left: String(localized: "Slowly turn 20° to one side and hold")
        case .farLeft: String(localized: "Turn farther to about 40° and hold")
        case .right: String(localized: "Face forward, then turn 20° the other way")
        case .farRight: String(localized: "Turn farther to about 40° and hold")
        case .forehead: String(localized: "Face forward, then lower your chin")
        case .chin: String(localized: "Gently lift your chin")
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

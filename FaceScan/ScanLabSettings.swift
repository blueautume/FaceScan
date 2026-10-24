import Foundation

/// Preview-only controls. These settings never change the captured points or export data.
struct ScanLabSettings: Equatable, Sendable {
    var displayMode: ScanLabDisplayMode = .points
    var colorMode: ScanLabColorMode = .captured
    var background: ScanLabBackground = .warm
    var pointSize: Double = 1.6
    var pointDensity: Double = 1
    var opacity: Double = 1
    var exposure: Double = 1
    var saturation: Double = 1
    var glow: Double = 0.2
    var additiveBlending = false

    var flyInEnabled = true
    var flyInDuration: Double = 0.8
    var flyInDistance: Double = 0.18
    var flyInSpread: Double = 0.07
    var flyInSwirl: Double = 0.6
    var flyInStagger: Double = 0.25
    var pulseEnabled = false
    var pulseSpeed: Double = 1
    var pulseAmplitude: Double = 0.002

    var filterEnabled = false
    var filterMode: ScanLabFilterMode = .spatialMean
    var filterStrength: Double = 0.5
    var filterRadius: Double = 0.006
    var filterPasses = 1
    var outlierRemovalEnabled = false
    var outlierMinNeighbors = 2

    var meshEnabled = false
    var meshOpacity: Double = 0.3
    var meshEdgeLimit: Double = 0.012
    var meshStride = 2
    var smoothNormals = true
    var metalness: Double = 0
    var roughness: Double = 0.6
    var lightIntensity: Double = 1_000

    var autoRotate = false
    var rotationSpeed: Double = 0.25
    var orthographic = false
    var showAxes = false
    var showBounds = false
    var showCameraPreview = true
    var showCoverage = true
    var showStats = true
    var demoNoise: Double = 0.0015

    mutating func apply(_ preset: ScanLabPreset) {
        // Presets change the preview look while preserving the user's overlay choices.
        let cameraPreview = showCameraPreview
        let coverage = showCoverage
        let stats = showStats
        let noise = demoNoise
        self = ScanLabSettings()
        showCameraPreview = cameraPreview
        showCoverage = coverage
        showStats = stats
        demoNoise = noise

        switch preset {
        case .original:
            flyInEnabled = false
            glow = 0
        case .convergence:
            colorMode = .champagne
            background = .midnight
            pointSize = 2.1
            glow = 0.65
            flyInDuration = 1.4
            flyInDistance = 0.28
            flyInSpread = 0.12
            flyInSwirl = 1.2
            flyInStagger = 0.45
        case .digitalGrid:
            displayMode = .hybrid
            colorMode = .cyan
            background = .black
            pointSize = 1.2
            glow = 0.5
            meshEnabled = true
            meshOpacity = 0.35
            filterEnabled = true
            filterMode = .bilateral
            filterStrength = 0.4
        case .sculpture:
            displayMode = .surface
            colorMode = .champagne
            background = .light
            meshEnabled = false
            meshOpacity = 1
            filterEnabled = true
            filterMode = .spatialMean
            filterStrength = 0.6
            filterPasses = 2
            flyInEnabled = false
            metalness = 0.25
            roughness = 0.45
            lightIntensity = 650
            exposure = 0.9
            glow = 0
        case .xray:
            displayMode = .xray
            colorMode = .cyan
            background = .midnight
            opacity = 0.45
            glow = 0.7
            additiveBlending = true
            pointSize = 1.8
            pulseEnabled = true
            pulseAmplitude = 0.001
        }
    }
}

enum ScanLabDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case points, surface, wireframe, hybrid, xray
    var id: String { rawValue }
    var title: String {
        switch self {
        case .points: "粒子点云"
        case .surface: "实体表面"
        case .wireframe: "三角线框"
        case .hybrid: "点云 + 网格"
        case .xray: "透视叠加"
        }
    }
}

enum ScanLabColorMode: String, CaseIterable, Identifiable, Sendable {
    case captured, champagne, cyan, depth, height, normals
    var id: String { rawValue }
    var title: String {
        switch self {
        case .captured: "采集原色"
        case .champagne: "香槟金"
        case .cyan: "冰蓝"
        case .depth: "深度渐变"
        case .height: "高度渐变"
        case .normals: "法线方向"
        }
    }
}

enum ScanLabBackground: String, CaseIterable, Identifiable, Sendable {
    case warm, black, midnight, light
    var id: String { rawValue }
    var title: String {
        switch self {
        case .warm: "暖深棕"
        case .black: "纯黑"
        case .midnight: "午夜蓝"
        case .light: "浅米白"
        }
    }
}

enum ScanLabFilterMode: String, CaseIterable, Identifiable, Sendable {
    case spatialMean, bilateral, median
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spatialMean: "空间均值"
        case .bilateral: "双边滤波"
        case .median: "中值滤波"
        }
    }
    var explanation: String {
        switch self {
        case .spatialMean: "平均附近点的位置，表面更平整；强度过高会软化细节。"
        case .bilateral: "按空间距离与表面差异加权，兼顾平滑和鼻唇等细节。"
        case .median: "参考附近点的位置中值，压制局部突刺。"
        }
    }
}

enum ScanLabPreset: String, CaseIterable, Identifiable, Sendable {
    case original, convergence, digitalGrid, sculpture, xray
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "原始"
        case .convergence: "粒子凝聚"
        case .digitalGrid: "数字网格"
        case .sculpture: "雕塑"
        case .xray: "透视"
        }
    }
    var symbol: String {
        switch self {
        case .original: "circle.dotted"
        case .convergence: "sparkles"
        case .digitalGrid: "square.grid.3x3"
        case .sculpture: "person.crop.square"
        case .xray: "square.3.layers.3d"
        }
    }
}

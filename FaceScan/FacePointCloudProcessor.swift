// FacePointCloudProcessor.swift
// Pure Swift / Foundation reference. iOS 15+, Swift 6.
//
// 对应此前四份 TrueDepth 点云的统一观感处理策略：
// SOR(k=20, 2.5σ) → 柱面中位融合 → 5×5 掩码中值 → 双边 3 次
// → 局部 RGB 去噪 → 排除径向移动超过 15mm 的点 → 输出 RGB 点云。
//
// 接入要点：
// 1. 输入必须是米制、ARFaceAnchor 局部坐标，+Y 向上，+Z 朝脸前方。
//    当前帧世界坐标转脸局部：inverse(faceAnchor.transform) * worldPoint。
//    先把深度相机点正确转到世界坐标；这里不负责 RGB/深度同步、标定或帧配准。
// 2. 采集完成后处理整份快照。不要在每个 ARFrame 或主线程反复执行。
// 3. let result = try await FacePointCloudProcessor.processAsync(points)
//    let displayPoints = result.points
// 4. 原三角面不能直接复用；结果只有点，索引见 result.sourceIndices。
// 5. 这是观感处理，会改变测量值、压掉多值结构；不能用于测量。
//
// 默认参数与 Python unified_faces.py 相同。算法不依赖 Python、Open3D、
// ARKit、SceneKit、Metal 或任何第三方库；底部包含精确 3D KD-tree。
// 可选 smoothingCurve 在原始局部起伏上评估几何强度；nil 保留原参考路径。

import Foundation

public struct FaceCloudPoint: Sendable {
    public var position: SIMD3<Float>
    /// 原始 8-bit RGB，范围 0...255；不要传入 0...1 后直接转 UInt8。
    public var color: SIMD3<UInt8>
    nonisolated public init(position: SIMD3<Float>, color: SIMD3<UInt8>) {
        self.position = position
        self.color = color
    }
}

public struct FaceCloudConfiguration: Sendable {
    public var sorNeighbors = 20
    public var sorStandardDeviations: Double = 2.5
    public var cylinderCenterX: Double = 0
    public var cylinderCenterZ: Double = -0.05
    public var referenceRadius: Double = 0.10
    /// 参数域采样间距。theta 方向对应 referenceRadius * theta，不是处处相等的真实弧长。
    public var parameterGridSize: Double = 0.0015
    public var medianWindow = 5
    public var minimumMedianObservations = 5
    public var bilateralIterations = 3
    public var bilateralHalfWindow = 4
    public var bilateralSpatialSigma: Double = 0.003
    public var bilateralRadiusSigma: Double = 0.006
    public var colorRadialGate: Double = 0.004
    public var colorSpatialSigma: Double = 0.0015
    public var colorRGBSigma: Double = 25
    public var colorHalfWindow = 2
    public var maximumRadialDisplacement: Double = 0.015
    /// 默认 true 与之前的结果一致；false 时只改几何，保留每个来源点的原始 RGB。
    public var filterColors = true
    /// nil uses the reference geometry unchanged. The curve affects geometry
    /// displacement only; SOR and optional RGB filtering remain independent.
    public var smoothingCurve: FaceCloudSmoothingCurve? = nil
    /// 防止单位或坐标错误导致二维栅格过大。不是滤波参数。
    public var maximumGridCells = 1_000_000
    nonisolated public init() {}
    nonisolated public static let reference = FaceCloudConfiguration()
}

public struct FaceCloudStatistics: Sendable, Codable {
    public let inputCount: Int
    public let outputCount: Int
    public let sorRejectedCount: Int
    /// 不符合单径向表面模型的样本，其中也可能包含真实的耳/颈/背面结构。
    public let modelRejectedCount: Int
    public let sorDistanceThresholdMM: Double
    public let medianDisplacementMM: Double
    public let p95DisplacementMM: Double
    public let maximumDisplacementMM: Double
    public let observedGridCells: Int
    public let elapsedSeconds: Double
}

public struct FaceCloudResult: Sendable {
    public let points: [FaceCloudPoint]
    /// points[i] 来自输入 sourceIndices[i]；输出保持原来的点顺序。
    public let sourceIndices: [Int]
    public let statistics: FaceCloudStatistics
}

public enum FaceCloudProcessingError: Error, Sendable, LocalizedError {
    case invalidConfiguration(String)
    case invalidCoordinate(Int)
    case tooFewPoints(required: Int, actual: Int)
    case gridTooLarge
    case noSupportedPoints
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return "无效处理参数：" + message
        case .invalidCoordinate(let i): return "第 \(i) 个点坐标无效；请使用有限的米制坐标。"
        case .tooFewPoints(let required, let actual): return "至少需要 \(required) 个点，当前 \(actual) 个。"
        case .gridTooLarge: return "柱面栅格过大；请检查米/毫米单位、人脸局部坐标及参数。"
        case .noSupportedPoints: return "没有符合单层表面模型的点。"
        }
    }
}

/// Bounds callback traffic even for large scans. All mutable state is protected
/// by the lock; callers may safely forward the callback across worker tasks.
/// This only throttles completed-work reports and never advances by a timer.
final class FPCProgressReporter: @unchecked Sendable {
    private let handler: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var lastValue = -1.0
    private var lastTime = -Double.infinity

    nonisolated init(_ handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }

    nonisolated func report(_ fraction: Double, force: Bool = false) {
        guard fraction.isFinite else { return }
        let value = min(1, max(0, fraction))
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard value > lastValue,
              force || value == 1 || (value - lastValue >= 0.002 && now - lastTime >= 0.04) else {
            lock.unlock()
            return
        }
        lastValue = value
        lastTime = now
        lock.unlock()
        handler(value)
    }
}

public enum FacePointCloudProcessor: Sendable {
    /// 同步 CPU 实现。调用方负责放到后台；闭包也在处理线程上执行。
    nonisolated public static func process(
        _ input: [FaceCloudPoint],
        configuration p: FaceCloudConfiguration = .reference,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> FaceCloudResult {
        let start = Date.timeIntervalSinceReferenceDate
        try validate(p)
        guard input.count > p.sorNeighbors else {
            throw FaceCloudProcessingError.tooFewPoints(required: p.sorNeighbors + 1, actual: input.count)
        }
        let check: () throws -> Void = {
            if isCancelled() { throw CancellationError() }
        }
        try check()
        // Fractions describe completed work within actual algorithm stages,
        // rather than elapsed time. Disabled passes contribute no work units.
        let weights: [Double] = [2, 4, 35, 8,
            p.smoothingCurve != nil && p.smoothingCurve?.uniformStrength == nil ? 16 : 0,
            p.medianWindow > 1 ? 8 : 1, Double(p.bilateralIterations) * 6,
            8, p.filterColors ? 12 : 0, 10, 1]
        let totalWeight = weights.reduce(0, +)
        var completedWeight = 0.0
        let stages = weights.map { weight -> (lower: Double, span: Double) in
            defer { completedWeight += weight }
            return (completedWeight / totalWeight, weight / totalWeight)
        }
        let progress = FPCProgressReporter(onProgress)
        func report(_ stage: Int, _ fraction: Double, force: Bool = false) {
            progress.report(stages[stage].lower + stages[stage].span * fraction, force: force)
        }
        progress.report(0, force: true)
        var positions = [SIMD3<Double>]()
        positions.reserveCapacity(input.count)
        for (i, point) in input.enumerated() {
            if i & 1023 == 0 {
                try check()
                report(0, Double(i) / Double(input.count))
            }
            let a = point.position
            guard a.x.isFinite, a.y.isFinite, a.z.isFinite,
                  abs(a.x) < 1000, abs(a.y) < 1000, abs(a.z) < 1000 else {
                throw FaceCloudProcessingError.invalidCoordinate(i)
            }
            positions.append(SIMD3(Double(a.x), Double(a.y), Double(a.z)))
        }
        report(0, 1, force: true)
        let tree = FPCExactKDTree(points: positions, onProgress: { report(1, $0) })
        report(1, 1, force: true)
        let distances = try tree.meanNeighborDistances(
            k: p.sorNeighbors, onProgress: { report(2, $0) }, checkCancellation: check)
        let mean = distances.reduce(0, +) / Double(distances.count)
        let variance = distances.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(distances.count)
        let sorThreshold = mean + p.sorStandardDeviations * sqrt(variance)
        let inliers = distances.indices.filter { distances[$0] <= sorThreshold }
        guard !inliers.isEmpty else { throw FaceCloudProcessingError.noSupportedPoints }
        try check()
        report(2, 1, force: true)

        // Chart: u = referenceRadius * atan2(x - cx, z - cz), v = y.
        let ntDouble = ceil(2 * Double.pi * p.referenceRadius / p.parameterGridSize)
        guard ntDouble >= 1, ntDouble <= Double(p.maximumGridCells) else {
            throw FaceCloudProcessingError.gridTooLarge
        }
        let nt = Int(ntDouble), dy = p.parameterGridSize
        let du = 2 * Double.pi * p.referenceRadius / Double(nt)
        var theta = [Double](), radius = [Double](), absoluteY = [Int]()
        theta.reserveCapacity(inliers.count); radius.reserveCapacity(inliers.count)
        absoluteY.reserveCapacity(inliers.count)
        for (ordinal, i) in inliers.enumerated() {
            if ordinal & 1023 == 0 {
                try check()
                report(3, 0.15 * Double(ordinal) / Double(inliers.count))
            }
            let a = positions[i]
            theta.append(atan2(a.x - p.cylinderCenterX, a.z - p.cylinderCenterZ))
            radius.append(hypot(a.x - p.cylinderCenterX, a.z - p.cylinderCenterZ))
            let cellY = floor(a.y / dy)
            guard abs(cellY) < Double(Int.max / 4) else { throw FaceCloudProcessingError.gridTooLarge }
            absoluteY.append(Int(cellY))
        }
        let y0 = absoluteY.min()!, y1 = absoluteY.max()!
        guard y1 >= y0, y1 - y0 < p.maximumGridCells else { throw FaceCloudProcessingError.gridTooLarge }
        let nv = y1 - y0 + 1
        guard nt <= p.maximumGridCells / nv else { throw FaceCloudProcessingError.gridTooLarge }
        let cells = nt * nv
        var binIDs = [Int](repeating: 0, count: inliers.count)
        var counts = [Int](repeating: 0, count: cells)
        for i in inliers.indices {
            if i & 1023 == 0 {
                try check()
                report(3, 0.15 + 0.15 * Double(i) / Double(inliers.count))
            }
            let u = FPCGrid.wrap(Int(floor((theta[i] + .pi) / (2 * .pi) * Double(nt))), nt)
            let id = u * nv + absoluteY[i] - y0
            binIDs[i] = id; counts[id] += 1
        }
        // Packed bins avoid one heap allocation per cell.
        var offsets = [Int](repeating: 0, count: cells + 1)
        for c in 0..<cells {
            if c & 4095 == 0 {
                try check()
                report(3, 0.3 + 0.2 * Double(c) / Double(cells))
            }
            offsets[c + 1] = offsets[c] + counts[c]
        }
        var cursor = offsets
        var members = [Int](repeating: 0, count: inliers.count)
        for i in inliers.indices {
            if i & 1023 == 0 {
                try check()
                report(3, 0.5 + 0.15 * Double(i) / Double(inliers.count))
            }
            let c = binIDs[i]; members[cursor[c]] = i; cursor[c] += 1
        }
        let active = counts.indices.filter { counts[$0] > 0 }
        var observed = [Bool](repeating: false, count: cells)
        var rGrid = [Double](repeating: 0, count: cells)
        var scratch = [Double](); scratch.reserveCapacity(max(25, counts.max() ?? 0))
        for (ordinal, c) in active.enumerated() {
            if ordinal & 1023 == 0 {
                try check()
                report(3, 0.65 + 0.35 * Double(ordinal) / Double(active.count))
            }
            observed[c] = true; scratch.removeAll(keepingCapacity: true)
            for j in offsets[c]..<offsets[c + 1] { scratch.append(radius[members[j]]) }
            rGrid[c] = FPCGrid.median(&scratch)
        }
        report(3, 1, force: true)

        // Measure the original observations before any spatial smoothing. A
        // fitted local tilt is removed so a sloping cheek is not a feature.
        let variation: [Double]?
        if let curve = p.smoothingCurve, curve.uniformStrength == nil {
            variation = try FPCAdaptiveSmoothing.localVariation(
                radii: rGrid, observed: observed, active: active, nu: nt, nv: nv,
                du: du, dv: dy, radius: curve.neighborhoodRadius,
                onProgress: { report(4, $0) }, checkCancellation: check)
        } else { variation = nil }
        report(4, 1, force: true)

        // Masked median: only actual observed bins contribute.
        var surface = rGrid
        let mh = p.medianWindow / 2
        for (ordinal, c) in active.enumerated() {
            if ordinal & 1023 == 0 {
                try check()
                report(5, Double(ordinal) / Double(active.count))
            }
            scratch.removeAll(keepingCapacity: true)
            let u = c / nv, v = c % nv
            for a in -mh...mh {
                let uu = FPCGrid.wrap(u + a, nt)
                for b in -mh...mh {
                    let vv = v + b
                    if vv >= 0 && vv < nv {
                        let q = uu * nv + vv
                        if observed[q] { scratch.append(rGrid[q]) }
                    }
                }
            }
            if scratch.count >= p.minimumMedianObservations { surface[c] = FPCGrid.median(&scratch) }
        }
        report(5, 1, force: true)
        let spatial = FPCGrid.kernel(half: p.bilateralHalfWindow, du: du, dv: dy,
                                     sigma: p.bilateralSpatialSigma)
        let radiusDenominator = 2 * p.bilateralRadiusSigma * p.bilateralRadiusSigma
        for iteration in 0..<p.bilateralIterations {
            var next = surface
            for (ordinal, c) in active.enumerated() {
                if ordinal & 1023 == 0 {
                    try check()
                    report(6, (Double(iteration) + Double(ordinal) / Double(active.count))
                        / Double(p.bilateralIterations))
                }
                let u = c / nv, v = c % nv
                var numerator = 0.0, denominator = 0.0
                for tap in spatial {
                    let vv = v + tap.dv
                    if vv < 0 || vv >= nv { continue }
                    let q = FPCGrid.wrap(u + tap.du, nt) * nv + vv
                    if !observed[q] { continue }
                    let diff = surface[q] - surface[c]
                    let w = tap.weight * exp(-diff * diff / radiusDenominator)
                    numerator += w * surface[q]; denominator += w
                }
                next[c] = numerator / max(denominator, 1e-15)
            }
            surface = next
        }
        try check()
        report(6, 1, force: true)
        // Exact separable squared-Euclidean feature transform, with periodic theta.
        // Empty bins are filled only for bilinear interpolation, never as observations.
        let nearest = try FPCGrid.nearestObservedMap(observed, nu: nt, nv: nv,
            onProgress: { report(7, $0) }, checkCancellation: check)
        report(7, 1, force: true)
        var colorGrid = [SIMD3<Double>](repeating: .zero, count: cells)
        if p.filterColors {
            var red = [Double](), green = [Double](), blue = [Double]()
            for (ordinal, c) in active.enumerated() {
                if ordinal & 1023 == 0 {
                    try check()
                    report(8, 0.5 * Double(ordinal) / Double(active.count))
                }
                red.removeAll(keepingCapacity: true); green.removeAll(keepingCapacity: true)
                blue.removeAll(keepingCapacity: true)
                for j in offsets[c]..<offsets[c + 1] {
                    let i = members[j]
                    if abs(radius[i] - rGrid[c]) <= p.colorRadialGate {
                        let col = input[inliers[i]].color
                        red.append(Double(col.x)); green.append(Double(col.y)); blue.append(Double(col.z))
                    }
                }
                if red.isEmpty {
                    for j in offsets[c]..<offsets[c + 1] {
                        let col = input[inliers[members[j]]].color
                        red.append(Double(col.x)); green.append(Double(col.y)); blue.append(Double(col.z))
                    }
                }
                colorGrid[c] = SIMD3(FPCGrid.median(&red), FPCGrid.median(&green), FPCGrid.median(&blue))
            }
            let colorKernel = FPCGrid.kernel(half: p.colorHalfWindow, du: du, dv: dy,
                                             sigma: p.colorSpatialSigma)
            let colorDenominator = 2 * p.colorRGBSigma * p.colorRGBSigma
            var smoothed = colorGrid
            for (ordinal, c) in active.enumerated() {
                if ordinal & 1023 == 0 {
                    try check()
                    report(8, 0.5 + 0.5 * Double(ordinal) / Double(active.count))
                }
                let u = c / nv, v = c % nv
                var sum = SIMD3<Double>.zero, norm = 0.0
                for tap in colorKernel {
                    let vv = v + tap.dv
                    if vv < 0 || vv >= nv { continue }
                    let q = FPCGrid.wrap(u + tap.du, nt) * nv + vv
                    if !observed[q] { continue }
                    let dc = colorGrid[q] - colorGrid[c], dr = surface[q] - surface[c]
                    let w = tap.weight * exp(-(dc.x*dc.x + dc.y*dc.y + dc.z*dc.z) / colorDenominator
                                               - dr * dr / radiusDenominator)
                    sum += colorGrid[q] * w; norm += w
                }
                smoothed[c] = sum / max(norm, 1e-15)
            }
            colorGrid = smoothed
        }
        report(8, 1, force: true)
        var output = [FaceCloudPoint](), sources = [Int](), movements = [Double]()
        output.reserveCapacity(inliers.count); sources.reserveCapacity(inliers.count)
        movements.reserveCapacity(inliers.count)
        for i in inliers.indices {
            if i & 2047 == 0 {
                try check()
                report(9, Double(i) / Double(inliers.count))
            }
            let source = inliers[i], a = positions[source]
            let sample = FPCGrid.sample(theta: theta[i], y: a.y, nu: nt, nv: nv, dy: dy,
                                        y0: y0, nearest: nearest)
            var r = 0.0, col = SIMD3<Double>.zero
            for j in 0..<4 {
                let index = sample.indices[j], w = sample.weights[j]
                r += surface[index] * w
                if p.filterColors { col += colorGrid[index] * w }
            }
            var b = SIMD3(p.cylinderCenterX + r * sin(theta[i]), a.y,
                          p.cylinderCenterZ + r * cos(theta[i]))
            if let curve = p.smoothingCurve {
                let strength: Double
                if let uniform = curve.uniformStrength { strength = uniform }
                else if let variation {
                    var local = 0.0
                    var supported = true
                    for j in 0..<4 where sample.weights[j] > 0 {
                        let value = variation[sample.indices[j]]
                        if !value.isFinite { supported = false; break }
                        local += value * sample.weights[j]
                    }
                    // Within-cell layers can be absent from the median grid;
                    // protect a source that differs strongly from that median.
                    let withinCell = abs(radius[i] - rGrid[binIDs[i]])
                    strength = supported ? curve.strength(for: max(local, withinCell)) : 0
                } else { strength = 0 }
                if strength == 0 { b = a }
                else if strength < 1 { b = a + (b - a) * strength }
            }
            let dx = b.x - a.x, dz = b.z - a.z
            let movement = sqrt(dx * dx + dz * dz)
            if movement > p.maximumRadialDisplacement { continue }
            let rgb: SIMD3<UInt8>
            if p.filterColors {
                rgb = SIMD3(FPCGrid.byte(col.x), FPCGrid.byte(col.y), FPCGrid.byte(col.z))
            } else { rgb = input[source].color }
            output.append(FaceCloudPoint(position: SIMD3(Float(b.x), Float(b.y), Float(b.z)), color: rgb))
            sources.append(source); movements.append(movement * 1000)
        }
        guard !output.isEmpty else { throw FaceCloudProcessingError.noSupportedPoints }
        report(9, 1, force: true)
        try check()
        movements.sort()
        let stats = FaceCloudStatistics(
            inputCount: input.count, outputCount: output.count,
            sorRejectedCount: input.count - inliers.count,
            modelRejectedCount: inliers.count - output.count,
            sorDistanceThresholdMM: sorThreshold * 1000,
            medianDisplacementMM: FPCGrid.quantile(movements, 0.5),
            p95DisplacementMM: FPCGrid.quantile(movements, 0.95),
            maximumDisplacementMM: movements.last!, observedGridCells: active.count,
            elapsedSeconds: Date.timeIntervalSinceReferenceDate - start)
        try check()
        progress.report(1, force: true)
        return FaceCloudResult(points: output, sourceIndices: sources, statistics: stats)
    }

    /// 后台单次处理。取消调用方 Task 时，会取消实际处理任务。
    /// 请在用户结束扫描时调用，保留任务句柄以支持界面取消。
    nonisolated public static func processAsync(
        _ input: [FaceCloudPoint], configuration: FaceCloudConfiguration = .reference,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> FaceCloudResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try process(input, configuration: configuration, onProgress: onProgress,
                        isCancelled: { Task.isCancelled })
        }
        return try await withTaskCancellationHandler(operation: {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        }, onCancel: { worker.cancel() })
    }

    nonisolated private static func validate(_ p: FaceCloudConfiguration) throws {
        let positives = [p.referenceRadius, p.parameterGridSize, p.bilateralSpatialSigma,
                         p.bilateralRadiusSigma, p.colorSpatialSigma, p.colorRGBSigma]
        let nonnegative = [p.sorStandardDeviations, p.colorRadialGate, p.maximumRadialDisplacement]
        guard positives.allSatisfy({ $0.isFinite && $0 > 0 }),
              nonnegative.allSatisfy({ $0.isFinite && $0 >= 0 }),
              p.cylinderCenterX.isFinite, p.cylinderCenterZ.isFinite,
              (1...1024).contains(p.sorNeighbors), p.medianWindow >= 1, p.medianWindow <= 31,
              p.medianWindow % 2 == 1, p.minimumMedianObservations >= 1,
              p.minimumMedianObservations <= p.medianWindow * p.medianWindow,
              (0...32).contains(p.bilateralIterations), (0...15).contains(p.bilateralHalfWindow),
              (0...15).contains(p.colorHalfWindow), (1...2_000_000).contains(p.maximumGridCells),
              p.smoothingCurve?.isValid ?? true else {
            throw FaceCloudProcessingError.invalidConfiguration("尺寸、sigma、邻点数或窗口范围不合法")
        }
    }
}

/// The metric is radial RMS around a fitted affine patch, not semantic face
/// recognition or mathematical curvature. Unknown/sparse patches are NaN and
/// conservatively retain their original geometry under a nonuniform curve.
enum FPCAdaptiveSmoothing {
    nonisolated static func localVariation(
        radii: [Double], observed: [Bool], active: [Int], nu: Int, nv: Int,
        du: Double, dv: Double, radius: Double,
        onProgress: (Double) -> Void = { _ in },
        checkCancellation: () throws -> Void = {}
    ) throws -> [Double] {
        var result = [Double](repeating: .nan, count: radii.count)
        guard du.isFinite, du > 0, dv.isFinite, dv > 0,
              radius.isFinite, radius > 0 else { return result }

        // Bounded sampling avoids an unbounded O(radius/gridSize)^2 kernel at
        // very fine grid settings. The usual settings sample every nearby bin.
        let desiredU = min(radius / du, Double(max(0, (nu - 1) / 2)))
        let desiredV = min(radius / dv, Double(max(0, nv - 1)))
        let stepU = max(1, Int(ceil(desiredU / 12)))
        let stepV = max(1, Int(ceil(desiredV / 12)))
        let halfU = min(12, Int(floor(desiredU / Double(stepU))))
        let halfV = min(12, Int(floor(desiredV / Double(stepV))))
        struct Tap { let u: Int; let v: Int; let x: Double; let y: Double }
        var taps: [Tap] = []
        for u in -halfU...halfU {
            for v in -halfV...halfV {
                let x = Double(u * stepU) * du / radius
                let y = Double(v * stepV) * dv / radius
                if x * x + y * y <= 1 + 1e-12 {
                    taps.append(Tap(u: u * stepU, v: v * stepV, x: x, y: y))
                }
            }
        }
        for (ordinal, cell) in active.enumerated() {
            if ordinal & 63 == 0 {
                try checkCancellation()
                onProgress(Double(ordinal) / Double(active.count))
            }
            let u = cell / nv, v = cell % nv
            var count = 0.0
            var sx = 0.0, sy = 0.0, sz = 0.0
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            var sxz = 0.0, syz = 0.0, szz = 0.0
            for tap in taps {
                let vv = v + tap.v
                if vv < 0 || vv >= nv { continue }
                let q = FPCGrid.wrap(u + tap.u, nu) * nv + vv
                if !observed[q] { continue }
                let x = tap.x, y = tap.y, z = radii[q] - radii[cell]
                count += 1
                sx += x; sy += y; sz += z
                sxx += x * x; syy += y * y; sxy += x * y
                sxz += x * z; syz += y * z; szz += z * z
            }
            guard count >= 6 else { continue }
            let xx = sxx - sx * sx / count, yy = syy - sy * sy / count
            let xy = sxy - sx * sy / count
            let xz = sxz - sx * sz / count, yz = syz - sy * sz / count
            let zz = szz - sz * sz / count
            let determinant = xx * yy - xy * xy
            guard xx > 1e-12, yy > 1e-12,
                  determinant > 1e-10 * xx * yy else { continue }
            let slopeX = (xz * yy - yz * xy) / determinant
            let slopeY = (yz * xx - xz * xy) / determinant
            let residual = zz - slopeX * xz - slopeY * yz
            result[cell] = sqrt(max(0, residual / count))
        }
        try checkCancellation()
        onProgress(1)
        return result
    }
}

private enum FPCGrid: Sendable {
    struct Tap: Sendable { let du: Int; let dv: Int; let weight: Double }
    nonisolated static func wrap(_ x: Int, _ n: Int) -> Int { let r = x % n; return r < 0 ? r + n : r }
    nonisolated static func byte(_ x: Double) -> UInt8 { UInt8(min(255, max(0, x.rounded(.toNearestOrEven)))) }
    nonisolated static func median(_ values: inout [Double]) -> Double {
        precondition(!values.isEmpty); values.sort()
        let n = values.count
        return n % 2 == 1 ? values[n / 2] : (values[n / 2 - 1] + values[n / 2]) * 0.5
    }
    nonisolated static func quantile(_ sorted: [Double], _ fraction: Double) -> Double {
        let x = Double(sorted.count - 1) * fraction, a = Int(floor(x)), b = Int(ceil(x))
        return sorted[a] * (1 - (x - Double(a))) + sorted[b] * (x - Double(a))
    }
    nonisolated static func kernel(half: Int, du: Double, dv: Double, sigma: Double) -> [Tap] {
        var result = [Tap]()
        for a in -half...half { for b in -half...half {
            let d = Double(a)*Double(a)*du*du + Double(b)*Double(b)*dv*dv
            result.append(Tap(du: a, dv: b, weight: exp(-d / (2 * sigma * sigma))))
        }}
        return result
    }
    struct Sample: Sendable { let indices: SIMD4<Int>; let weights: SIMD4<Double> }
    nonisolated static func sample(theta: Double, y: Double, nu: Int, nv: Int, dy: Double, y0: Int,
                       nearest: [Int]) -> Sample {
        let rawU = (theta + .pi) / (2 * .pi) * Double(nu) - 0.5
        let u = rawU - floor(rawU / Double(nu)) * Double(nu)
        let v = min(Double(nv - 1), max(0, y / dy - Double(y0) - 0.5))
        let u0 = Int(floor(u)), u1 = wrap(u0 + 1, nu)
        let v0 = Int(floor(v)), v1 = min(v0 + 1, nv - 1)
        let a = u - Double(u0), b = v - Double(v0)
        return Sample(indices: SIMD4(nearest[u0*nv+v0], nearest[u0*nv+v1],
                                     nearest[u1*nv+v0], nearest[u1*nv+v1]),
                      weights: SIMD4((1-a)*(1-b), (1-a)*b, a*(1-b), a*b))
    }
    /// 1D exact squared-distance transform, retaining the nearest input site.
    nonisolated static func transform(_ f: [Double]) -> (distance: [Double], owner: [Int]) {
        let sites = f.indices.filter { f[$0].isFinite }
        if sites.isEmpty { return ([Double](repeating: .infinity, count: f.count),
                                   [Int](repeating: -1, count: f.count)) }
        var v = [Int](repeating: 0, count: sites.count)
        var z = [Double](repeating: 0, count: sites.count + 1)
        var k = 0; v[0] = sites[0]; z[0] = -.infinity; z[1] = .infinity
        for q in sites.dropFirst() {
            var t = v[k]
            var s = ((f[q] + Double(q)*Double(q)) - (f[t] + Double(t)*Double(t))) / (2 * Double(q - t))
            while k > 0 && s <= z[k] {
                k -= 1; t = v[k]
                s = ((f[q] + Double(q)*Double(q)) - (f[t] + Double(t)*Double(t))) / (2 * Double(q - t))
            }
            k += 1; v[k] = q; z[k] = s; z[k+1] = .infinity
        }
        k = 0
        var distances = [Double](repeating: 0, count: f.count)
        var owners = [Int](repeating: 0, count: f.count)
        for q in f.indices {
            while z[k+1] < Double(q) { k += 1 }
            let d = Double(q - v[k]); distances[q] = d*d + f[v[k]]; owners[q] = v[k]
        }
        return (distances, owners)
    }
    nonisolated static func nearestObservedMap(
        _ mask: [Bool], nu: Int, nv: Int,
        onProgress: (Double) -> Void, checkCancellation: () throws -> Void
    ) throws -> [Int] {
        let width = nu * 3
        var firstDistance = [Double](repeating: 0, count: width * nv)
        var firstOwner = [Int](repeating: 0, count: width * nv)
        var column = [Double](repeating: 0, count: width)
        for y in 0..<nv {
            if y & 15 == 0 {
                try checkCancellation()
                onProgress(0.5 * Double(y) / Double(nv))
            }
            for u in 0..<width { column[u] = mask[(u % nu) * nv + y] ? 0 : .infinity }
            let t = transform(column)
            for u in 0..<width {
                firstDistance[u*nv+y] = t.distance[u]
                firstOwner[u*nv+y] = t.owner[u] < 0 ? -1 : (t.owner[u] % nu)*nv + y
            }
        }
        var map = [Int](repeating: 0, count: nu*nv)
        var row = [Double](repeating: 0, count: nv)
        // Only central tile results are needed after the second pass.
        for u in nu..<(2*nu) {
            if (u - nu) & 15 == 0 {
                try checkCancellation()
                onProgress(0.5 + 0.5 * Double(u - nu) / Double(nu))
            }
            for y in 0..<nv { row[y] = firstDistance[u*nv+y] }
            let t = transform(row)
            for y in 0..<nv { map[(u-nu)*nv+y] = firstOwner[u*nv+t.owner[y]] }
        }
        try checkCancellation()
        onProgress(1)
        return map
    }
}

// MARK: - Exact nearest-neighbour backend

/// Exact 3-D nearest-neighbour lookup used by the SOR stage.
/// Value-semantic and Sendable. Excludes only the query's own array index;
/// another point at exactly the same coordinates remains a valid neighbour.
internal struct FPCExactKDTree: Sendable {
    private let points: [SIMD3<Double>]
    /// A balanced tree stored implicitly: the midpoint of each range is its root.
    private let order: [Int]

    nonisolated internal init(points: [SIMD3<Double>], onProgress: (Double) -> Void = { _ in }) {
        self.points = points
        var indices = Array(points.indices)
        var completed = 0
        Self.build(&indices, points: points, lower: 0, upper: indices.count, axis: 0,
                   completed: &completed, onProgress: onProgress)
        self.order = indices
        onProgress(1)
    }

    /// Mean Euclidean distance to k other samples, in the input coordinate units.
    /// k is clamped to N-1 for this helper; the public processor validates its input.
    /// Cancellation is checked every 256 queries, including before the first one.
    nonisolated internal func meanNeighborDistances(
        k: Int,
        onProgress: (Double) -> Void = { _ in },
        checkCancellation: () throws -> Void = {}
    ) throws -> [Double] {
        try checkCancellation()
        let count = points.count
        let neighbourCount = min(max(k, 0), max(count - 1, 0))
        guard neighbourCount > 0 else { return Array(repeating: 0, count: count) }
        var result = Array(repeating: 0.0, count: count)
        // Reuse one fixed-size max heap for all queries; no allocation per point.
        var heap = Array(repeating: 0.0, count: neighbourCount)
        for index in points.indices {
            if index & 255 == 0 {
                try checkCancellation()
                onProgress(Double(index) / Double(count))
            }
            var used = 0
            search(lower: 0, upper: order.count, axis: 0,
                   query: points[index], excluding: index,
                   k: neighbourCount, heap: &heap, used: &used)
            var sum = 0.0
            for slot in 0..<used { sum += heap[slot].squareRoot() }
            result[index] = sum / Double(used)
        }
        onProgress(1)
        return result
    }

    nonisolated private static func build(
        _ indices: inout [Int], points: [SIMD3<Double>],
        lower: Int, upper: Int, axis: Int,
        completed: inout Int, onProgress: (Double) -> Void
    ) {
        guard upper - lower > 1 else {
            completed += max(0, upper - lower)
            if completed & 255 == 0, !points.isEmpty {
                onProgress(Double(completed) / Double(points.count))
            }
            return
        }
        let middle = lower + (upper - lower) / 2
        select(&indices, points: points, lower: lower, upper: upper,
               target: middle, axis: axis)
        completed += 1
        if completed & 255 == 0 { onProgress(Double(completed) / Double(points.count)) }
        let nextAxis = (axis + 1) % 3
        build(&indices, points: points, lower: lower, upper: middle, axis: nextAxis,
              completed: &completed, onProgress: onProgress)
        build(&indices, points: points, lower: middle + 1, upper: upper, axis: nextAxis,
              completed: &completed, onProgress: onProgress)
    }

    /// Coordinate plus source-index ordering makes duplicate coordinates deterministic.
    nonisolated private static func less(
        _ lhs: Int, _ rhs: Int, points: [SIMD3<Double>], axis: Int
    ) -> Bool {
        let a = points[lhs][axis]
        let b = points[rhs][axis]
        return a < b || (a == b && lhs < rhs)
    }

    /// In-place nth-element with median-of-three pivots. A depth budget provides
    /// an O(M log M) sorting fallback for pathological quickselect partitions.
    nonisolated private static func select(
        _ indices: inout [Int], points: [SIMD3<Double>],
        lower: Int, upper: Int, target: Int, axis: Int
    ) {
        var left = lower
        var right = upper - 1
        var budget = 2 * max(1, Int(log2(Double(max(upper - lower, 2)))))
        while left < right {
            if budget == 0 {
                let sorted = indices[left...right].sorted {
                    less($0, $1, points: points, axis: axis)
                }
                indices.replaceSubrange(left...right, with: sorted)
                return
            }
            budget -= 1
            let middle = left + (right - left) / 2
            if less(indices[middle], indices[left], points: points, axis: axis) {
                indices.swapAt(middle, left)
            }
            if less(indices[right], indices[left], points: points, axis: axis) {
                indices.swapAt(right, left)
            }
            if less(indices[right], indices[middle], points: points, axis: axis) {
                indices.swapAt(right, middle)
            }
            indices.swapAt(middle, right)
            let pivot = indices[right]
            var store = left
            if left < right {
                for index in left..<right {
                    if less(indices[index], pivot, points: points, axis: axis) {
                        if store != index { indices.swapAt(store, index) }
                        store += 1
                    }
                }
            }
            indices.swapAt(store, right)
            if store == target { return }
            if store < target { left = store + 1 }
            else { right = store - 1 }
        }
    }

    nonisolated private func search(
        lower: Int, upper: Int, axis: Int,
        query: SIMD3<Double>, excluding excludedIndex: Int,
        k: Int, heap: inout [Double], used: inout Int
    ) {
        guard lower < upper else { return }
        let middle = lower + (upper - lower) / 2
        let pointIndex = order[middle]
        let point = points[pointIndex]
        if pointIndex != excludedIndex {
            let d = point - query
            let squaredDistance = d.x * d.x + d.y * d.y + d.z * d.z
            if used < k {
                var child = used
                heap[child] = squaredDistance
                used += 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    if heap[parent] >= heap[child] { break }
                    heap.swapAt(parent, child)
                    child = parent
                }
            } else if squaredDistance < heap[0] {
                heap[0] = squaredDistance
                var parent = 0
                while true {
                    let left = parent * 2 + 1
                    if left >= used { break }
                    let right = left + 1
                    let larger = right < used && heap[right] > heap[left] ? right : left
                    if heap[parent] >= heap[larger] { break }
                    heap.swapAt(parent, larger)
                    parent = larger
                }
            }
        }
        let difference = query[axis] - point[axis]
        let nextAxis = (axis + 1) % 3
        if difference <= 0 {
            search(lower: lower, upper: middle, axis: nextAxis,
                   query: query, excluding: excludedIndex, k: k, heap: &heap, used: &used)
            // Strict comparison is safe: points on an equal-distance plane
            // cannot improve the retained distances, even when coordinates repeat.
            if used < k || difference * difference < heap[0] {
                search(lower: middle + 1, upper: upper, axis: nextAxis,
                       query: query, excluding: excludedIndex, k: k, heap: &heap, used: &used)
            }
        } else {
            search(lower: middle + 1, upper: upper, axis: nextAxis,
                   query: query, excluding: excludedIndex, k: k, heap: &heap, used: &used)
            if used < k || difference * difference < heap[0] {
                search(lower: lower, upper: middle, axis: nextAxis,
                       query: query, excluding: excludedIndex, k: k, heap: &heap, used: &used)
            }
        }
    }
}

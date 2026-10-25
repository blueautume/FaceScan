import Foundation
import simd

struct PointCloudEnhancementResult: Sendable {
    let vertices: [ScanVertex]
    let originalPointCount: Int
    let addedPointCount: Int
    let elapsedSeconds: Double
    let reachedLimit: Bool
}

/// Builds an optional display buffer from the final selected scan. Source points
/// are never moved or removed. New samples lie on supported local surface patches;
/// they are interpolated presentation data, not additional depth measurements.
enum PointCloudDisplayEnhancer {
    enum EnhancementError: Error, LocalizedError {
        case invalidSettings
        case invalidVertex(Int)

        var errorDescription: String? {
            switch self {
            case .invalidSettings: "呈现增强参数无效，请检查点间距、补点范围和数量上限。"
            case .invalidVertex(let index): "第 \(index + 1) 个点包含无效坐标或颜色，无法增强。"
            }
        }
    }

    nonisolated static func process(_ vertices: [ScanVertex],
                                    settings: ScanEnhancementSettings) throws -> PointCloudEnhancementResult {
        try Task.checkCancellation()
        guard settings.isValid else { throw EnhancementError.invalidSettings }
        let start = Date.timeIntervalSinceReferenceDate
        for (index, vertex) in vertices.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let p = vertex.position, c = vertex.color
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
                  abs(p.x) <= 2, abs(p.y) <= 2, abs(p.z) <= 2,
                  c.x.isFinite, c.y.isFinite, c.z.isFinite,
                  (0...1).contains(c.x), (0...1).contains(c.y), (0...1).contains(c.z) else {
                throw EnhancementError.invalidVertex(index)
            }
        }
        guard vertices.count >= 6, vertices.count < settings.maximumPointCount else {
            return PointCloudEnhancementResult(vertices: vertices, originalPointCount: vertices.count,
                addedPointCount: 0, elapsedSeconds: Date.timeIntervalSinceReferenceDate - start,
                reachedLimit: !vertices.isEmpty && vertices.count >= settings.maximumPointCount)
        }

        let sourceIndex = try EnhancementSourceIndex(vertices: vertices, cellSize: settings.supportRadius)
        let occupancy = EnhancementOccupancy(cellSize: settings.targetSpacing)
        for (index, vertex) in vertices.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            occupancy.insert(vertex.position)
        }
        var output = vertices
        output.reserveCapacity(min(settings.maximumPointCount, vertices.count * 4))
        var cache = [EnhancementPatch?](repeating: nil, count: vertices.count)
        var examined = [Bool](repeating: false, count: vertices.count)
        let spacing = Double(settings.targetSpacing)
        let spacingSquared = settings.targetSpacing * settings.targetSpacing
        let colorLimitSquared = pow(Double(settings.colorTolerance) / 255, 2)
        let protection = Double(settings.edgeProtection)
        let rmsLimit = spacing * (0.95 - 0.8 * protection)
        let planeLimit = spacing * (1.5 - 1.25 * protection)
        let normalCosine = cos((60 - 45 * protection) * .pi / 180)
        let maxEdgeSquared = Double(settings.maximumGap * settings.maximumGap)
        var random = EnhancementRandom(seed: settings.seed)
        var attempts = 0
        // A fixed work bound also prevents pathological sparse/duplicate inputs
        // from turning a requested small display enhancement into an unbounded job.
        let maximumAttempts = min(8_000_000, max(20_000, (settings.maximumPointCount - vertices.count) * 40))

        func patch(at index: Int) -> EnhancementPatch? {
            if examined[index] { return cache[index] }
            examined[index] = true
            let neighbors = sourceIndex.nearest(to: index, count: 24, colorLimitSquared: colorLimitSquared)
            guard neighbors.count >= 5 else { return nil }
            let pointIDs = [index] + neighbors.map(\.index)
            guard let fit = EnhancementPatch.fit(pointIDs.map { vertices[$0].position }),
                  fit.rms <= rmsLimit else { return nil }
            cache[index] = fit
            return fit
        }

        anchorLoop: for anchor in vertices.indices {
            if anchor.isMultiple(of: 32) { try Task.checkCancellation() }
            if output.count >= settings.maximumPointCount || attempts >= maximumAttempts { break }
            let candidates = sourceIndex.nearest(to: anchor, count: 24, colorLimitSquared: colorLimitSquared)
            guard candidates.count >= 5 else { continue }
            // Dense source regions need no extra points. The occupancy check
            // below remains exact and includes every original source point.
            let near = candidates.prefix(6).map(\.distanceSquared).sorted()
            if near[near.count / 2] < spacingSquared * 0.8 { continue }
            guard let base = patch(at: anchor) else { continue }
            let origin = SIMD3<Double>(vertices[anchor].position)

            struct Ray { let index: Int; let angle: Double; let lengthSquared: Double }
            var rays: [Int: Ray] = [:]
            for neighbor in candidates {
                let index = neighbor.index
                let delta = SIMD3<Double>(vertices[index].position) - origin
                let lengthSquared = simd_length_squared(delta)
                guard lengthSquared <= maxEdgeSquared, lengthSquared > spacing * spacing * 0.01,
                      abs(simd_dot(delta, base.normal)) <= planeLimit,
                      let other = patch(at: index),
                      abs(simd_dot(base.normal, other.normal)) >= normalCosine else { continue }
                let x = simd_dot(delta, base.tangent), y = simd_dot(delta, base.bitangent)
                let angle = atan2(y, x)
                let sector = min(15, Int(floor((angle + .pi) / (2 * .pi) * 16)))
                if let old = rays[sector], old.lengthSquared <= lengthSquared { continue }
                rays[sector] = Ray(index: index, angle: angle, lengthSquared: lengthSquared)
            }
            let ring = rays.values.sorted { $0.angle == $1.angle ? $0.index < $1.index : $0.angle < $1.angle }
            guard ring.count >= 2 else { continue }
            for ray in ring.indices {
                let first = ring[ray], second = ring[(ray + 1) % ring.count]
                var angle = second.angle - first.angle
                if angle <= 0 { angle += 2 * .pi }
                // Do not close the fan across a missing half of a neighborhood.
                guard angle < .pi * 0.8 else { continue }
                let a = vertices[anchor], b = vertices[first.index], c = vertices[second.index]
                let pa = SIMD3<Double>(a.position), pb = SIMD3<Double>(b.position), pc = SIMD3<Double>(c.position)
                guard simd_length_squared(pb - pc) <= maxEdgeSquared,
                      simd_length_squared(SIMD3<Double>(b.color) - SIMD3<Double>(c.color)) <= colorLimitSquared else { continue }
                let area = simd_length(simd_cross(pb - pa, pc - pa)) * 0.5
                guard area >= spacing * spacing * 0.25 else { continue }
                let sampleCount = min(24, max(3, Int(ceil(area / (spacing * spacing) * 5))))
                for _ in 0..<sampleCount {
                    attempts += 1
                    if attempts.isMultiple(of: 128) { try Task.checkCancellation() }
                    if output.count >= settings.maximumPointCount || attempts >= maximumAttempts { break anchorLoop }
                    let root = sqrt(random.unit())
                    let u = 1 - root, v = root * (1 - random.unit()), w = 1 - u - v
                    let candidate = pa * u + pb * v + pc * w
                    let offset = simd_dot(base.center - candidate, base.normal)
                    guard abs(offset) <= planeLimit else { continue }
                    let projected = candidate + base.normal * offset
                    let position = SIMD3<Float>(projected)
                    guard abs(position.x) <= 2, abs(position.y) <= 2, abs(position.z) <= 2,
                          !occupancy.hasPoint(closerThan: settings.targetSpacing, to: position) else { continue }
                    // Position comes from this supported patch, and its color
                    // uses exactly the same compatible source triangle.
                    let color = a.color * Float(u) + b.color * Float(v) + c.color * Float(w)
                    output.append(ScanVertex(position: position, color: simd_clamp(color, .zero, SIMD3(repeating: 1))))
                    occupancy.insert(position)
                }
            }
        }
        try Task.checkCancellation()
        return PointCloudEnhancementResult(vertices: output, originalPointCount: vertices.count,
            addedPointCount: output.count - vertices.count,
            elapsedSeconds: Date.timeIntervalSinceReferenceDate - start,
            reachedLimit: output.count >= settings.maximumPointCount)
    }

    nonisolated static func processAsync(_ vertices: [ScanVertex],
                                         settings: ScanEnhancementSettings) async throws -> PointCloudEnhancementResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { try process(vertices, settings: settings) }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }
}

private struct EnhancementCell: Hashable {
    let x: Int
    let y: Int
    let z: Int

    init(_ p: SIMD3<Float>, scale: Float) {
        x = Int(floor(p.x / scale)); y = Int(floor(p.y / scale)); z = Int(floor(p.z / scale))
    }
    init(_ x: Int, _ y: Int, _ z: Int) { self.x = x; self.y = y; self.z = z }
}

private struct EnhancementNeighbor {
    let index: Int
    let distanceSquared: Float
}

private struct EnhancementSourceIndex {
    let vertices: [ScanVertex]
    let cellSize: Float
    let buckets: [EnhancementCell: [Int]]

    init(vertices: [ScanVertex], cellSize: Float) throws {
        self.vertices = vertices
        self.cellSize = cellSize
        var buckets: [EnhancementCell: [Int]] = [:]
        for (index, vertex) in vertices.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            buckets[EnhancementCell(vertex.position, scale: cellSize), default: []].append(index)
        }
        self.buckets = buckets
    }

    func nearest(to source: Int, count: Int, colorLimitSquared: Double) -> [EnhancementNeighbor] {
        let point = vertices[source], key = EnhancementCell(point.position, scale: cellSize)
        let limit = cellSize * cellSize
        var nearest: [EnhancementNeighbor] = []
        nearest.reserveCapacity(count + 1)
        for z in -1...1 { for y in -1...1 { for x in -1...1 {
            guard let members = buckets[EnhancementCell(key.x + x, key.y + y, key.z + z)] else { continue }
            // At normal scan densities all entries are visited. For extremely
            // dense/duplicate buckets, deterministic striding bounds analysis.
            let stride = max(1, (members.count + 127) / 128)
            for offset in Swift.stride(from: 0, to: members.count, by: stride) {
                let index = members[offset]
                guard index != source else { continue }
                let vertex = vertices[index]
                let distance = simd_length_squared(vertex.position - point.position)
                guard distance <= limit,
                      simd_length_squared(SIMD3<Double>(vertex.color) - SIMD3<Double>(point.color)) <= colorLimitSquared else { continue }
                if nearest.count == count, let last = nearest.last,
                   distance > last.distanceSquared || distance == last.distanceSquared && index >= last.index { continue }
                let item = EnhancementNeighbor(index: index, distanceSquared: distance)
                var lower = 0, upper = nearest.count
                while lower < upper {
                    let middle = (lower + upper) / 2, other = nearest[middle]
                    if other.distanceSquared < distance || other.distanceSquared == distance && other.index < index {
                        lower = middle + 1
                    } else { upper = middle }
                }
                nearest.insert(item, at: lower)
                if nearest.count > count { nearest.removeLast() }
            }
        }}}
        return nearest
    }
}

/// Exact minimum-distance rejection includes every original point, including
/// source duplicates. Generated points are inserted only after acceptance.
private final class EnhancementOccupancy {
    final class Bucket {
        var positions: [SIMD3<Float>] = []
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
    }
    let cellSize: Float
    private var buckets: [EnhancementCell: Bucket] = [:]
    init(cellSize: Float) { self.cellSize = cellSize }

    func insert(_ position: SIMD3<Float>) {
        let key = EnhancementCell(position, scale: cellSize)
        let bucket: Bucket
        if let existing = buckets[key] { bucket = existing }
        else { bucket = Bucket(); buckets[key] = bucket }
        bucket.positions.append(position)
        bucket.low = simd_min(bucket.low, position)
        bucket.high = simd_max(bucket.high, position)
    }

    func hasPoint(closerThan distance: Float, to point: SIMD3<Float>) -> Bool {
        let cell = EnhancementCell(point, scale: cellSize), squared = distance * distance
        for z in -1...1 { for y in -1...1 { for x in -1...1 {
            guard let bucket = buckets[EnhancementCell(cell.x + x, cell.y + y, cell.z + z)] else { continue }
            let separation = simd_max(simd_max(bucket.low - point, point - bucket.high), .zero)
            if simd_length_squared(separation) >= squared { continue }
            for other in bucket.positions where simd_length_squared(point - other) < squared { return true }
        }}}
        return false
    }
}

private struct EnhancementPatch {
    let center: SIMD3<Double>
    let normal: SIMD3<Double>
    let tangent: SIMD3<Double>
    let bitangent: SIMD3<Double>
    let rms: Double

    static func fit(_ points: [SIMD3<Float>]) -> EnhancementPatch? {
        guard points.count >= 6 else { return nil }
        let center = points.reduce(SIMD3<Double>.zero) { $0 + SIMD3<Double>($1) } / Double(points.count)
        var matrix = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for point in points {
            let p = SIMD3<Double>(point) - center
            for row in 0..<3 { for column in row..<3 { matrix[row][column] += p[row] * p[column] } }
        }
        for row in 0..<3 { for column in 0..<row { matrix[row][column] = matrix[column][row] } }
        var vectors = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]
        for _ in 0..<16 {
            var p = 0, q = 1
            for row in 0..<3 { for column in (row + 1)..<3 {
                if abs(matrix[row][column]) > abs(matrix[p][q]) { p = row; q = column }
            }}
            let cross = matrix[p][q]
            if abs(cross) < 1e-18 { break }
            let tau = (matrix[q][q] - matrix[p][p]) / (2 * cross)
            let t = (tau >= 0 ? 1.0 : -1.0) / (abs(tau) + sqrt(1 + tau * tau))
            let cosine = 1 / sqrt(1 + t * t), sine = t * cosine
            let pp = matrix[p][p], qq = matrix[q][q]
            for r in 0..<3 where r != p && r != q {
                let rp = matrix[r][p], rq = matrix[r][q]
                matrix[r][p] = cosine * rp - sine * rq; matrix[p][r] = matrix[r][p]
                matrix[r][q] = sine * rp + cosine * rq; matrix[q][r] = matrix[r][q]
            }
            matrix[p][p] = pp - t * cross; matrix[q][q] = qq + t * cross
            matrix[p][q] = 0; matrix[q][p] = 0
            for r in 0..<3 {
                let rp = vectors[r][p], rq = vectors[r][q]
                vectors[r][p] = cosine * rp - sine * rq
                vectors[r][q] = sine * rp + cosine * rq
            }
        }
        let order = (0..<3).sorted { matrix[$0][$0] < matrix[$1][$1] }
        guard matrix[order[1]][order[1]] > 1e-12 else { return nil }
        var normal = SIMD3(vectors[0][order[0]], vectors[1][order[0]], vectors[2][order[0]])
        var largest = 0
        for axis in 1..<3 where abs(normal[axis]) > abs(normal[largest]) { largest = axis }
        if normal[largest] < 0 { normal = -normal }
        let axis = abs(normal.x) < 0.8 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let tangent = simd_normalize(simd_cross(normal, axis))
        let bitangent = simd_cross(normal, tangent)
        return EnhancementPatch(center: center, normal: normal, tangent: tangent, bitangent: bitangent,
                                rms: sqrt(max(0, matrix[order[0]][order[0]]) / Double(points.count)))
    }
}

private struct EnhancementRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func unit() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value >> 11) / 9_007_199_254_740_992
    }
}

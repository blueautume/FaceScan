import Foundation
import simd

/// A disposable display copy. Its indices always refer to `vertices`; sourceIndices
/// retain the relationship to captured points for animation and comparison.
struct ScanLabProcessedGeometry: Sendable {
    var vertices: [ScanVertex]
    var triangleIndices: [UInt32]
    var normals: [SIMD3<Float>]
    var sourceIndices: [Int]
    var originalPointCount: Int
}

/// Preview-only geometry processing. Capture, measured topology and export never
/// consume this result. Work is bounded even if all points occupy one hash cell.
enum ScanLabGeometryProcessor {
    static let maximumDisplayPoints = 24_000
    private static let maximumBucketSamples = 48
    private static let maximumNeighbors = 96

    static func process(vertices: [ScanVertex], triangleIndices: [UInt32] = [],
                        settings: ScanLabSettings) -> ScanLabProcessedGeometry {
        let originalCount = vertices.count
        if Task.isCancelled { return emptyResult(originalPointCount: originalCount) }
        var validIndices: [Int] = []
        validIndices.reserveCapacity(vertices.count)
        for index in vertices.indices {
            if index.isMultiple(of: 1_024), Task.isCancelled {
                return emptyResult(originalPointCount: originalCount)
            }
            if isValid(vertices[index]) { validIndices.append(index) }
        }
        let density = finite(settings.pointDensity, fallback: 1, range: 0...1)
        let displayCount = min(maximumDisplayPoints,
                               Int((Double(validIndices.count) * density).rounded(.up)))
        let sampled = uniformSample(validIndices, count: displayCount)
        var preview = sampled.map { vertices[$0] }
        var sourceIndices = sampled
        let radius = Float(finite(settings.filterRadius, fallback: 0.006,
                                  range: 0.0001...0.1))
        let strength = Float(finite(settings.filterStrength, fallback: 0.5, range: 0...1))

        if settings.outlierRemovalEnabled, !preview.isEmpty {
            let spatialIndex = SpatialIndex(vertices: preview, cellSize: radius)
            let required = max(1, min(maximumNeighbors, settings.outlierMinNeighbors))
            var retained: [Int] = []
            retained.reserveCapacity(preview.count)
            for index in preview.indices {
                if index.isMultiple(of: 128), Task.isCancelled {
                    return emptyResult(originalPointCount: originalCount)
                }
                if spatialIndex.neighbors(of: index, in: preview, radius: radius).count >= required {
                    retained.append(index)
                }
            }
            preview = retained.map { preview[$0] }
            sourceIndices = retained.map { sourceIndices[$0] }
        }

        if settings.filterEnabled, strength > 0, !preview.isEmpty {
            for _ in 0..<max(1, min(5, settings.filterPasses)) {
                if Task.isCancelled { return emptyResult(originalPointCount: originalCount) }
                let input = preview
                let spatialIndex = SpatialIndex(vertices: input, cellSize: radius)
                for index in input.indices {
                    if index.isMultiple(of: 128), Task.isCancelled {
                        return emptyResult(originalPointCount: originalCount)
                    }
                    let neighbors = spatialIndex.neighbors(of: index, in: input, radius: radius)
                    guard !neighbors.isEmpty else { continue }
                    let position = input[index].position
                    let filtered: SIMD3<Float>
                    switch settings.filterMode {
                    case .spatialMean:
                        var total = position
                        for neighbor in neighbors { total += input[neighbor.index].position }
                        filtered = total / Float(neighbors.count + 1)
                    case .bilateral:
                        // The face-local Z range term preserves depth steps, such
                        // as a nose edge, while spatial weights smooth nearby noise.
                        let spatialVariance = max(radius * radius * 0.5, 1e-12)
                        let depthSigma = max(radius * 0.12, 0.000025)
                        let depthVariance = 2 * depthSigma * depthSigma
                        var total = position
                        var totalWeight: Float = 1
                        for neighbor in neighbors {
                            let candidate = input[neighbor.index].position
                            let deltaZ = candidate.z - position.z
                            let weight = exp(-neighbor.distanceSquared / spatialVariance
                                             - deltaZ * deltaZ / depthVariance)
                            total += candidate * weight
                            totalWeight += weight
                        }
                        filtered = total / totalWeight
                    case .median:
                        var xs = [position.x]
                        var ys = [position.y]
                        var zs = [position.z]
                        for neighbor in neighbors {
                            let candidate = input[neighbor.index].position
                            xs.append(candidate.x)
                            ys.append(candidate.y)
                            zs.append(candidate.z)
                        }
                        filtered = SIMD3(median(xs), median(ys), median(zs))
                    }
                    let result = position + (filtered - position) * strength
                    if isFinite(result) { preview[index].position = result }
                }
            }
        }

        var faces: [UInt32] = []
        if settings.meshEnabled || settings.displayMode != .points {
            let limit = Float(finite(settings.meshEdgeLimit, fallback: 0.012,
                                     range: 0.0001...0.1))
            let stride = max(1, min(8, settings.meshStride))
            if triangleIndices.isEmpty {
                faces = projectedPreviewFaces(vertices: preview, edgeLimit: limit, stride: stride)
            } else {
                faces = remappedFaces(triangleIndices, vertices: preview,
                                      sourceIndices: sourceIndices, edgeLimit: limit)
            }
        }
        if Task.isCancelled { return emptyResult(originalPointCount: originalCount) }
        let normals = vertexNormals(vertices: preview, indices: faces)
        if Task.isCancelled { return emptyResult(originalPointCount: originalCount) }
        return ScanLabProcessedGeometry(vertices: preview, triangleIndices: faces,
                                        normals: normals,
                                        sourceIndices: sourceIndices,
                                        originalPointCount: originalCount)
    }

    private static func emptyResult(originalPointCount: Int) -> ScanLabProcessedGeometry {
        ScanLabProcessedGeometry(vertices: [], triangleIndices: [], normals: [],
                                 sourceIndices: [], originalPointCount: originalPointCount)
    }

    private static func finite(_ value: Double, fallback: Double,
                               range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value.isFinite ? value : fallback))
    }

    private static func isFinite(_ vector: SIMD3<Float>) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }

    private static func isValid(_ vertex: ScanVertex) -> Bool {
        isFinite(vertex.position) && isFinite(vertex.color)
            && vertex.color.x >= 0 && vertex.color.x <= 1
            && vertex.color.y >= 0 && vertex.color.y <= 1
            && vertex.color.z >= 0 && vertex.color.z <= 1
    }

    private static func uniformSample(_ indices: [Int], count: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count < indices.count else { return indices }
        guard count > 1 else { return [indices[indices.count / 2]] }
        return (0..<count).map {
            indices[Int(Double($0) * Double(indices.count - 1) / Double(count - 1))]
        }
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return sorted[middle - 1] * 0.5 + sorted[middle] * 0.5
        }
        return sorted[middle]
    }

    private struct Cell: Hashable {
        var x: Int64
        var y: Int64
        var z: Int64

        init(_ position: SIMD3<Float>, size: Float) {
            x = Self.coordinate(Double(position.x) / Double(size))
            y = Self.coordinate(Double(position.y) / Double(size))
            z = Self.coordinate(Double(position.z) / Double(size))
        }

        init(x: Int64, y: Int64, z: Int64) { self.x = x; self.y = y; self.z = z }

        // Leave room for adjacent-cell offsets and avoid Int conversion traps for
        // finite but astronomically large input positions.
        private static func coordinate(_ value: Double) -> Int64 {
            Int64(min(9e15, max(-9e15, floor(value))))
        }
    }

    private struct Neighbor {
        var index: Int
        var distanceSquared: Float
    }

    private struct SpatialIndex {
        private var buckets: [Cell: [Int]] = [:]
        private let cellSize: Float

        init(vertices: [ScanVertex], cellSize: Float) {
            self.cellSize = cellSize
            var counts: [Cell: Int] = [:]
            for index in vertices.indices {
                if index.isMultiple(of: 1_024), Task.isCancelled { return }
                let key = Cell(vertices[index].position, size: cellSize)
                let seen = counts[key, default: 0] + 1
                counts[key] = seen
                if buckets[key, default: []].count < maximumBucketSamples {
                    buckets[key, default: []].append(index)
                } else {
                    // Deterministic reservoir sampling represents the whole cell,
                    // without storing or visiting an unbounded list per query.
                    var hash = UInt64(index) &+ 0x9e3779b97f4a7c15
                    hash = (hash ^ (hash >> 30)) &* 0xbf58476d1ce4e5b9
                    hash = (hash ^ (hash >> 27)) &* 0x94d049bb133111eb
                    hash ^= hash >> 31
                    let replacement = Int(hash % UInt64(seen))
                    if replacement < maximumBucketSamples { buckets[key]?[replacement] = index }
                }
            }
        }

        func neighbors(of index: Int, in vertices: [ScanVertex], radius: Float) -> [Neighbor] {
            let position = vertices[index].position
            let key = Cell(position, size: cellSize)
            let radiusSquared = radius * radius
            var candidates: [Neighbor] = []
            for z in -1...1 {
                for y in -1...1 {
                    for x in -1...1 {
                        let neighborKey = Cell(x: key.x + Int64(x), y: key.y + Int64(y),
                                               z: key.z + Int64(z))
                        for other in buckets[neighborKey, default: []] where other != index {
                            let squared = simd_length_squared(vertices[other].position - position)
                            if squared.isFinite, squared <= radiusSquared {
                                candidates.append(Neighbor(index: other, distanceSquared: squared))
                            }
                        }
                    }
                }
            }
            if candidates.count > maximumNeighbors {
                candidates.sort {
                    $0.distanceSquared == $1.distanceSquared
                        ? $0.index < $1.index : $0.distanceSquared < $1.distanceSquared
                }
                candidates.removeLast(candidates.count - maximumNeighbors)
            }
            return candidates
        }
    }

    /// Keep every surviving measured face. Stride controls only the projected
    /// adjacency approximation; dropping measured faces would punch artificial
    /// checkerboard gaps into an otherwise continuous captured surface.
    private static func remappedFaces(_ indices: [UInt32], vertices: [ScanVertex],
                                      sourceIndices: [Int], edgeLimit: Float) -> [UInt32] {
        let remapping = Dictionary(uniqueKeysWithValues: sourceIndices.enumerated().map { ($1, $0) })
        var result: [UInt32] = []
        result.reserveCapacity(indices.count)
        for offset in Swift.stride(from: 0, to: indices.count - indices.count % 3, by: 3) {
            if offset.isMultiple(of: 3_072), Task.isCancelled { return [] }
            guard let a = remapping[Int(indices[offset])],
                  let b = remapping[Int(indices[offset + 1])],
                  let c = remapping[Int(indices[offset + 2])],
                  validTriangle(a, b, c, vertices: vertices, edgeLimit: edgeLimit) else { continue }
            result.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)])
        }
        return result
    }

    /// Adjacent occupied XY cells provide a display approximation only. No
    /// measured topology is inferred, no vertices are added and empty cells are
    /// never bridged. Three-dimensional edges and depth jumps are rejected.
    private static func projectedPreviewFaces(vertices: [ScanVertex], edgeLimit: Float,
                                              stride: Int) -> [UInt32] {
        guard vertices.count >= 3 else { return [] }
        var minimum = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for (index, vertex) in vertices.enumerated() {
            if index.isMultiple(of: 1_024), Task.isCancelled { return [] }
            minimum = simd_min(minimum, SIMD2(vertex.position.x, vertex.position.y))
            maximum = simd_max(maximum, SIMD2(vertex.position.x, vertex.position.y))
        }
        let width = Double(maximum.x) - Double(minimum.x)
        let height = Double(maximum.y) - Double(minimum.y)
        guard width > 0, height > 0 else { return [] }
        let estimatedSpacing = sqrt(width * height / Double(vertices.count)) * 1.25
        let cellSize = Float(min(Double(edgeLimit) * 0.6,
                                 max(Double(edgeLimit) * 0.12, estimatedSpacing) * Double(stride)))
        var grid: [Cell: Int] = [:]
        for index in vertices.indices {
            if index.isMultiple(of: 1_024), Task.isCancelled { return [] }
            let position = vertices[index].position
            let key = Cell(SIMD3(position.x, position.y, 0), size: cellSize)
            if let existing = grid[key] {
                // For overlapping projected samples retain the frontmost measured
                // point; never average two different surface layers into one.
                if vertices[existing].position.z < position.z { grid[key] = index }
            } else {
                grid[key] = index
            }
        }
        var result: [UInt32] = []
        let depthLimit = min(edgeLimit * 0.45, cellSize * 1.5)
        func append(_ a: Int?, _ b: Int?, _ c: Int?) {
            guard let a, let b, let c,
                  validTriangle(a, b, c, vertices: vertices, edgeLimit: edgeLimit) else { return }
            let depths = [vertices[a].position.z, vertices[b].position.z, vertices[c].position.z]
            guard let low = depths.min(), let high = depths.max(), high - low <= depthLimit else { return }
            result.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)])
        }
        // Sorting makes output stable across dictionary seeds and render passes.
        let cells = grid.keys.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        for (index, key) in cells.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return [] }
            let a = grid[key]
            let b = grid[Cell(x: key.x + 1, y: key.y, z: 0)]
            let c = grid[Cell(x: key.x, y: key.y + 1, z: 0)]
            let d = grid[Cell(x: key.x + 1, y: key.y + 1, z: 0)]
            if a != nil, b != nil, c != nil, d != nil {
                append(a, b, c)
                append(b, d, c)
            } else if d == nil {
                append(a, b, c)
            } else if b == nil {
                append(a, d, c)
            } else if c == nil {
                append(a, b, d)
            }
        }
        return result
    }

    private static func validTriangle(_ a: Int, _ b: Int, _ c: Int,
                                      vertices: [ScanVertex], edgeLimit: Float) -> Bool {
        guard a != b, b != c, a != c else { return false }
        let p = vertices[a].position
        let q = vertices[b].position
        let r = vertices[c].position
        let limitSquared = edgeLimit * edgeLimit
        let cross = simd_cross(q - p, r - p)
        let areaSquared = simd_length_squared(cross)
        return simd_length_squared(p - q) <= limitSquared
            && simd_length_squared(q - r) <= limitSquared
            && simd_length_squared(r - p) <= limitSquared
            && areaSquared.isFinite && areaSquared > 1e-16
    }

    private static func vertexNormals(vertices: [ScanVertex], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for offset in Swift.stride(from: 0, to: indices.count, by: 3) {
            if offset.isMultiple(of: 3_072), Task.isCancelled { return [] }
            let a = Int(indices[offset])
            let b = Int(indices[offset + 1])
            let c = Int(indices[offset + 2])
            let normal = simd_cross(vertices[b].position - vertices[a].position,
                                    vertices[c].position - vertices[a].position)
            normals[a] += normal
            normals[b] += normal
            normals[c] += normal
        }
        for index in normals.indices {
            if index.isMultiple(of: 1_024), Task.isCancelled { return [] }
            let normal = normals[index]
            let length = simd_length_squared(normal)
            normals[index] = length.isFinite && length > 1e-20
                ? normal / sqrt(length) : SIMD3(0, 0, 1)
        }
        return normals
    }
}

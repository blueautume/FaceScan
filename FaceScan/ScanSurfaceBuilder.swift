import simd

/// Indices remain stable while later depth frames replace point coordinates.
struct ScanTriangle {
    var a: Int
    var b: Int
    var c: Int
}

/// Builds the measured result independently of capture and rendering. A useful
/// point cloud remains exportable even when no triangle survives validation.
enum ScanSurfaceBuilder {
    static let minimumPointCount = 150

    static func confirmedPointCount(in indices: [Int],
                                    accumulators: [PointFusionAccumulator]) -> Int {
        var confirmed: Set<Int> = []
        for index in indices where accumulators.indices.contains(index)
            && accumulators[index].observedFrames >= 2 {
            confirmed.insert(index)
        }
        return confirmed.count
    }

    static func makeMesh(accumulators: [PointFusionAccumulator],
                         triangles: [ScanTriangle], frameCount: Int,
                         coveredAngles: Set<ScanAngle>) -> ScanMesh? {
        guard frameCount >= 2 else { return nil }
        // Several pixels from one depth frame cannot confirm a noisy sample.
        var remapping = [Int](repeating: -1, count: accumulators.count)
        var vertices: [ScanVertex] = []
        vertices.reserveCapacity(accumulators.count)
        for (oldIndex, accumulator) in accumulators.enumerated()
        where accumulator.observedFrames >= 2 {
            remapping[oldIndex] = vertices.count
            vertices.append(ScanVertex(position: accumulator.position,
                                       color: accumulator.color))
        }
        guard vertices.count >= minimumPointCount else { return nil }
        var outputIndices: [UInt32] = []
        outputIndices.reserveCapacity(triangles.count * 3)
        for triangle in triangles {
            guard remapping.indices.contains(triangle.a),
                  remapping.indices.contains(triangle.b),
                  remapping.indices.contains(triangle.c) else { continue }
            let a = remapping[triangle.a]
            let b = remapping[triangle.b]
            let c = remapping[triangle.c]
            guard a >= 0, b >= 0, c >= 0 else { continue }
            let p = vertices[a].position
            let q = vertices[b].position
            let r = vertices[c].position
            // Latest-frame replacement can invalidate a previously measured
            // face. Keep its points while dropping stretched/degenerate faces.
            guard simd_distance(p, q) < 0.014, simd_distance(q, r) < 0.014,
                  simd_distance(r, p) < 0.014,
                  simd_length_squared(simd_cross(q - p, r - p)) > 1e-13 else { continue }
            outputIndices.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)])
        }
        return ScanMesh(vertices: vertices, triangleIndices: outputIndices,
                        frameCount: frameCount, coveredAngles: coveredAngles)
    }
}

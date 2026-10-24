import Foundation
import simd

/// Reproducible synthetic noise makes preview filters comparable without a camera.
/// These vertices never enter the measured reconstructor or its exported scan.
enum ScanLabDemo {
    static func vertices(noise: Double) -> [ScanVertex] {
        mesh(noise: noise).vertices
    }

    static func mesh(noise: Double) -> ScanMesh {
        let amount = Float(min(max(noise.isFinite ? noise : 0, 0), 0.006))
        var result = SampleFaceMesh.make()
        let ordered = result.vertices.enumerated().map { index, original in
            var vertex = original
            let seed = Float(index)
            vertex.position += SIMD3(
                sin(seed * 1.713 + 0.3), sin(seed * 2.371 + 1.7),
                sin(seed * 3.117 + 2.8)) * amount
            return (index: index, vertex: vertex)
        }.sorted { abs($0.vertex.position.x) < abs($1.vertex.position.x) }
        var remap = [UInt32](repeating: 0, count: ordered.count)
        for (newIndex, item) in ordered.enumerated() { remap[item.index] = UInt32(newIndex) }
        result.vertices = ordered.map(\.vertex)
        result.triangleIndices = result.triangleIndices.map { remap[Int($0)] }
        return result
    }
}

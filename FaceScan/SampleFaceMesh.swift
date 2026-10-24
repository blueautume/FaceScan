import Foundation
import simd

/// A mathematical demonstration surface, never a camera scan or a recovered person's face.
/// It exists only to preview the three-dimensional viewer when a TrueDepth camera is unavailable.
enum SampleFaceMesh {
    static func make() -> ScanMesh {
        let columns = 133
        let rows = 169
        var vertices: [ScanVertex] = []
        var grid = Array(repeating: -1, count: columns * rows)
        vertices.reserveCapacity(columns * rows)

        for row in 0..<rows {
            let v = Float(row) / Float(rows - 1) * 2 - 1
            for column in 0..<columns {
                let u = Float(column) / Float(columns - 1) * 2 - 1
                let radiusSquared = u * u + v * v
                guard radiusSquared < 0.988 else { continue }
                // An open oval facial surface in meters; +Z faces the viewer.
                let jaw = v < -0.15 ? 1 + (v + 0.15) * 0.12 : 1
                let x = u * 0.075 * jaw
                let y = v * 0.114
                let roundness = sqrt(max(0, 1 - radiusSquared))
                var z = 0.026 * roundness - 0.008

                // Midface, nose bridge/tip, eye sockets, cheeks and chin.
                z += 0.008 * gaussian(x, y, 0, 0.050, 0.038, 0.050)
                z += 0.017 * gaussian(x, y, 0, 0.025, 0.008, 0.027)
                z += 0.027 * gaussian(x, y, 0, 0.004, 0.011, 0.012)
                z += 0.007 * gaussian(x, y, -0.011, -0.006, 0.005, 0.006)
                z += 0.007 * gaussian(x, y, 0.011, -0.006, 0.005, 0.006)
                for side: Float in [-1, 1] {
                    z -= 0.010 * gaussian(x, y, side * 0.031, 0.030, 0.016, 0.011)
                    z += 0.005 * gaussian(x, y, side * 0.032, 0.049, 0.020, 0.007)
                    z += 0.009 * gaussian(x, y, side * 0.037, -0.011, 0.020, 0.022)
                }
                // Two lip ridges with a shallow closed-mouth crease.
                z += 0.0048 * gaussian(x, y, 0, -0.031, 0.020, 0.0034)
                z += 0.0055 * gaussian(x, y, 0, -0.040, 0.020, 0.004)
                z -= 0.0025 * gaussian(x, y, 0, -0.0354, 0.022, 0.0014)
                z += 0.009 * gaussian(x, y, 0, -0.077, 0.027, 0.020)
                z -= 0.002 * gaussian(x, y, 0, -0.055, 0.023, 0.008)

                let index = vertices.count
                vertices.append(ScanVertex(position: SIMD3(x, y, z), color: color(x: x, y: y)))
                grid[row * columns + column] = index
            }
        }

        var triangles: [UInt32] = []
        triangles.reserveCapacity(vertices.count * 6)
        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let a = grid[row * columns + column]
                let b = grid[row * columns + column + 1]
                let c = grid[(row + 1) * columns + column]
                let d = grid[(row + 1) * columns + column + 1]
                // Row order goes upward, so these triangles have outward (+Z) winding.
                if a >= 0, b >= 0, c >= 0 { triangles += [UInt32(a), UInt32(b), UInt32(c)] }
                if b >= 0, d >= 0, c >= 0 { triangles += [UInt32(b), UInt32(d), UInt32(c)] }
            }
        }
        return ScanMesh(
            vertices: vertices, triangleIndices: triangles,
            frameCount: 0, coveredAngles: [], isSample: true
        )
    }

    private static func gaussian(_ x: Float, _ y: Float, _ centerX: Float, _ centerY: Float, _ width: Float, _ height: Float) -> Float {
        let dx = (x - centerX) / width
        let dy = (y - centerY) / height
        return exp(-0.5 * (dx * dx + dy * dy))
    }

    private static func color(x: Float, y: Float) -> SIMD3<Float> {
        var skin = SIMD3<Float>(0.76, 0.56, 0.45)
        let warmth = gaussian(x, y, -0.039, -0.011, 0.017, 0.020)
            + gaussian(x, y, 0.039, -0.011, 0.017, 0.020)
        skin += SIMD3(0.035, -0.015, -0.012) * warmth
        let lips = gaussian(x, y, 0, -0.0355, 0.020, 0.0055)
        skin = blend(skin, SIMD3(0.56, 0.29, 0.28), amount: lips * 0.65)

        for side: Float in [-1, 1] {
            let eyeX = side * 0.031
            let sclera = gaussian(x, y, eyeX, 0.030, 0.011, 0.0026)
            skin = blend(skin, SIMD3(0.78, 0.76, 0.70), amount: sclera * 0.83)
            let iris = gaussian(x, y, eyeX, 0.030, 0.0030, 0.0024)
            skin = blend(skin, SIMD3(0.19, 0.15, 0.11), amount: iris * 0.95)
            let eyebrow = gaussian(x, y, eyeX, 0.049, 0.017, 0.0026)
            skin = blend(skin, SIMD3(0.28, 0.21, 0.17), amount: eyebrow * 0.68)
            let nostril = gaussian(x, y, side * 0.0085, -0.009, 0.0033, 0.0019)
            skin = blend(skin, SIMD3(0.30, 0.20, 0.17), amount: nostril * 0.55)
        }
        return simd_clamp(skin, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    private static func blend(_ a: SIMD3<Float>, _ b: SIMD3<Float>, amount: Float) -> SIMD3<Float> {
        let t = min(max(amount, 0), 1)
        return a * (1 - t) + b * t
    }
}

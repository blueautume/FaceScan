import Foundation
import simd

/// Tracks stable point-array indices at their current fused positions. A cell
/// can contain several points after refinement moves an existing point across
/// its original voxel boundary; no point or mesh index is replaced or lost.
struct PointFusionSpatialIndex {
    private let voxelSize: Double
    private var cells: [Cell: [Int]] = [:]
    private var pointCells: [Int: Cell] = [:]

    init(voxelSize: Float = 0.002) {
        self.voxelSize = voxelSize.isFinite && voxelSize > 0 ? Double(voxelSize) : 0.002
    }

    mutating func reset() {
        cells.removeAll(keepingCapacity: true)
        pointCells.removeAll(keepingCapacity: true)
    }

    /// Invalid updates leave the previously indexed position unchanged.
    mutating func update(index: Int, position: SIMD3<Float>) {
        guard index >= 0, let newCell = cell(for: position) else { return }
        if let oldCell = pointCells[index] {
            guard oldCell != newCell else { return }
            if var oldIndices = cells[oldCell] {
                oldIndices.removeAll { $0 == index }
                if oldIndices.isEmpty {
                    cells.removeValue(forKey: oldCell)
                } else {
                    cells[oldCell] = oldIndices
                }
            }
        }
        cells[newCell, default: []].append(index)
        pointCells[index] = newCell
    }

    func indices(inSameCellAs position: SIMD3<Float>) -> [Int] {
        guard let key = cell(for: position) else { return [] }
        return cells[key] ?? []
    }

    /// Includes the center cell. Each point resides in exactly one cell, so
    /// neighborhood results contain no duplicate indices without a Set copy.
    func indices(inNeighborhoodOf position: SIMD3<Float>) -> [Int] {
        guard let center = cell(for: position) else { return [] }
        var result: [Int] = []
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let neighbor = Cell(x: center.x + Int64(dx), y: center.y + Int64(dy),
                                        z: center.z + Int64(dz))
                    if let indices = cells[neighbor] { result.append(contentsOf: indices) }
                }
            }
        }
        return result
    }

    private func cell(for position: SIMD3<Float>) -> Cell? {
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return nil }
        let scaled = SIMD3<Double>(position) / voxelSize
        // Leave room for neighbor offsets and keep Double-to-Int conversion
        // safely inside its exact integer range, even for malformed fixtures.
        let maximumCoordinate: Double = 4_503_599_627_370_495
        guard abs(scaled.x) <= maximumCoordinate, abs(scaled.y) <= maximumCoordinate,
              abs(scaled.z) <= maximumCoordinate else { return nil }
        return Cell(x: Int64(floor(scaled.x)), y: Int64(floor(scaled.y)),
                    z: Int64(floor(scaled.z)))
    }

    private struct Cell: Hashable {
        var x: Int64
        var y: Int64
        var z: Int64
    }
}

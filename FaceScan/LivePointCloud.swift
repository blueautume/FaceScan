import Foundation

/// A bounded copy of measured, fused points for the live viewer. Positions stay
/// in the reconstructor's anatomical face axes, in meters; rendering must not
/// normalize the coordinates differently from one update to the next.
struct LivePointCloudSnapshot: Sendable {
    var revision: Int
    var vertices: [ScanVertex]
    var confirmedPointCount: Int
    var isSample: Bool = false

    var pointCount: Int { vertices.count }
}

/// Selects stable vertices without first materializing every fused position and
/// color. Only integer indices span the whole scan; the vertex closure is called
/// at most maximumPoints times. Keep invocation on the reconstruction queue so
/// these two source closures observe the same accumulator state.
enum LivePointCloudSampler {
    static func makeSnapshot(sourceCount: Int, revision: Int,
                             maximumPoints: Int = 24_000,
                             observedFramesAt: (Int) -> Int,
                             vertexAt: (Int) -> ScanVertex) -> LivePointCloudSnapshot? {
        guard sourceCount > 0, revision >= 2, maximumPoints > 0 else { return nil }

        var confirmedIndices: [Int] = []
        confirmedIndices.reserveCapacity(sourceCount)
        for index in 0..<sourceCount where observedFramesAt(index) >= 2 {
            confirmedIndices.append(index)
        }
        guard !confirmedIndices.isEmpty else { return nil }

        let outputCount = min(maximumPoints, confirmedIndices.count)
        var vertices: [ScanVertex] = []
        vertices.reserveCapacity(outputCount)
        for outputIndex in 0..<outputCount {
            // Include both ends whenever there is room for two points. A prefix
            // would erase the forehead, chin and sides captured later in a scan.
            let rank = outputCount == 1 ? (confirmedIndices.count - 1) / 2
                : outputIndex * (confirmedIndices.count - 1) / (outputCount - 1)
            vertices.append(vertexAt(confirmedIndices[rank]))
        }
        return LivePointCloudSnapshot(revision: revision, vertices: vertices,
                                      confirmedPointCount: confirmedIndices.count)
    }
}

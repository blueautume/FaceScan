import Foundation

struct ScanFilterResult: Sendable {
    let mesh: ScanMesh
    let statistics: FaceCloudStatistics
}

/// Adapts completed, face-local meter-scale scans to the supplied reference pipeline.
enum ScanPointCloudFilter {
    enum FilterError: Error, LocalizedError {
        case emptyMesh
        case invalidVertex(Int)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .emptyMesh: "扫描中没有可以滤波的点。"
            case .invalidVertex(let index): "第 \(index + 1) 个点包含无效坐标或颜色，无法滤波。"
            case .emptyResult: "滤波后没有可显示的点，请保留原始结果并重新扫描。"
            }
        }
    }

    /// CPU work, including color conversion, runs on the caller's processing thread.
    nonisolated static func process(_ mesh: ScanMesh) throws -> ScanFilterResult {
        try Task.checkCancellation()
        guard !mesh.vertices.isEmpty else { throw FilterError.emptyMesh }
        var points: [FaceCloudPoint] = []
        points.reserveCapacity(mesh.vertices.count)
        for (index, vertex) in mesh.vertices.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let p = vertex.position, c = vertex.color
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
                  c.x.isFinite, c.y.isFinite, c.z.isFinite else {
                throw FilterError.invalidVertex(index)
            }
            points.append(FaceCloudPoint(position: p, color: SIMD3(byte(c.x), byte(c.y), byte(c.z))))
        }
        let result = try FacePointCloudProcessor.process(points, isCancelled: { Task.isCancelled })
        try Task.checkCancellation()
        guard !result.points.isEmpty else { throw FilterError.emptyResult }
        var vertices: [ScanVertex] = []
        vertices.reserveCapacity(result.points.count)
        for (index, point) in result.points.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            vertices.append(ScanVertex(position: point.position,
                                       color: SIMD3(Float(point.color.x), Float(point.color.y),
                                                    Float(point.color.z)) / 255))
        }
        try Task.checkCancellation()
        // The reference deletes/reprojects vertices; the measured triangle topology is no longer valid.
        let filtered = ScanMesh(vertices: vertices, triangleIndices: [], frameCount: mesh.frameCount,
                                coveredAngles: mesh.coveredAngles, isSample: mesh.isSample,
                                isFiltered: true)
        return ScanFilterResult(mesh: filtered, statistics: result.statistics)
    }

    nonisolated static func processAsync(_ mesh: ScanMesh) async throws -> ScanFilterResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { try process(mesh) }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated private static func byte(_ value: Float) -> UInt8 {
        UInt8((min(max(value, 0), 1) * 255).rounded(.toNearestOrEven))
    }
}

import Foundation

enum ScanExporter {
    private static var temporaryExportDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceScanExports", isDirectory: true)
    }

    /// Clears only unfinished staging files created before a local save.
    /// Completed files in Documents are retained. Run at launch and when local
    /// scan data is cleared, including consent withdrawal, to remove files left
    /// behind by an interrupted app session.
    static func removeTemporaryExports() {
        try? FileManager.default.removeItem(at: temporaryExportDirectory)
        // Remove staging left by the project's former name as well. User-saved
        // PLY files live outside these dedicated temporary directories.
        let legacyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceDepthExports", isDirectory: true)
        try? FileManager.default.removeItem(at: legacyDirectory)
    }

    enum ExportError: LocalizedError {
        case emptyMesh
        case invalidGeometry

        var errorDescription: String? {
            switch self {
            case .emptyMesh: return "扫描中没有可以导出的顶点。"
            case .invalidGeometry: return "扫描数据包含无效坐标或三角形。"
            }
        }
    }

    /// Saves a completed scan inside the app's local Documents directory.
    /// Staging is always removed; only a successfully returned file is retained.
    /// A supplied directory supports isolated local storage and deterministic
    /// tests. File-system errors propagate so the caller can show a useful error.
    static func saveLocally(_ mesh: ScanMesh, directory: URL? = nil) throws -> URL {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let destinationDirectory: URL
        if let directory {
            destinationDirectory = directory
        } else {
            destinationDirectory = try fileManager.url(for: .documentDirectory,
                                                       in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
        }
        let stagedURL = try export(mesh)
        defer { try? fileManager.removeItem(at: stagedURL) }
        try Task.checkCancellation()
        try fileManager.createDirectory(at: destinationDirectory,
                                        withIntermediateDirectories: true)
        let destination = destinationDirectory.appendingPathComponent(stagedURL.lastPathComponent)
        var moved = false
        do {
            try Task.checkCancellation()
            try fileManager.moveItem(at: stagedURL, to: destination)
            moved = true
            try Task.checkCancellation()
            return destination
        } catch {
            // Never remove a pre-existing user file when the move itself fails.
            if moved { try? fileManager.removeItem(at: destination) }
            throw error
        }
    }

    /// ASCII PLY is widely readable (for example in MeshLab and Blender), keeps
    /// measured coordinates in meters, and supports standard per-vertex color.
    /// Writes a complete staging file off the main thread; saveLocally moves it
    /// into Documents after successful completion.
    static func export(_ mesh: ScanMesh) throws -> URL {
        try Task.checkCancellation()
        guard !mesh.vertices.isEmpty else { throw ExportError.emptyMesh }
        guard mesh.triangleIndices.count.isMultiple(of: 3),
              mesh.triangleIndices.allSatisfy({ Int($0) < mesh.vertices.count }),
              mesh.vertices.allSatisfy({ vertex in
                  vertex.position.x.isFinite && vertex.position.y.isFinite && vertex.position.z.isFinite
                      && vertex.color.x.isFinite && vertex.color.y.isFinite && vertex.color.z.isFinite
              }) else { throw ExportError.invalidGeometry }
        try Task.checkCancellation()
        let kind = mesh.isSample ? "sample" : "truedepth"
        let filename = "FaceScan-\(kind)-\(UUID().uuidString.prefix(8)).ply"
        let directory = temporaryExportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        let header = """
        ply
        format ascii 1.0
        comment FaceScan \(mesh.isSample ? "synthetic sample - not a real scan" : "TrueDepth measured surface")
        comment coordinate_units meters
        comment coordinate_frame ARFaceAnchor local, +Y up, +Z face forward
        comment accepted_depth_frames \(mesh.frameCount)
        comment captured_views \(ScanAngle.allCases.filter { mesh.coveredAngles.contains($0) }.map(\.rawValue).joined(separator: ","))
        comment view_coverage \(mesh.coveredAngles.count)/\(ScanAngle.allCases.count)
        element vertex \(mesh.vertices.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        element face \(mesh.triangleIndices.count / 3)
        property list uchar uint vertex_indices
        end_header

        """
        // Chunk output to avoid holding several complete String/Data copies of
        // the scan in memory. String(Float) is locale independent (decimal '.').
        guard FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            var chunk = ""
            chunk.reserveCapacity(128_000)
            func flush() throws {
                if !chunk.isEmpty {
                    try handle.write(contentsOf: Data(chunk.utf8))
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            func byte(_ value: Float) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            // Revoking consent cancels the export task. Bound the amount of
            // work before cancellation is observed, then remove partial output.
            for (index, vertex) in mesh.vertices.enumerated() {
                if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
                let p = vertex.position
                let c = vertex.color
                chunk += "\(p.x) \(p.y) \(p.z) \(byte(c.x)) \(byte(c.y)) \(byte(c.z))\n"
                if chunk.utf8.count > 96_000 { try flush() }
            }
            for index in stride(from: 0, to: mesh.triangleIndices.count, by: 3) {
                if index.isMultiple(of: 3_072) { try Task.checkCancellation() }
                chunk += "3 \(mesh.triangleIndices[index]) \(mesh.triangleIndices[index + 1]) \(mesh.triangleIndices[index + 2])\n"
                if chunk.utf8.count > 96_000 { try flush() }
            }
            try Task.checkCancellation()
            try flush()
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }
}

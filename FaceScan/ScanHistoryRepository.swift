import CryptoKit
import Foundation

/// The original acquisition's metadata. `byteCount` is the lossless binary
/// payload size; viewing, filtering and exporting never modify this record.
struct ScanHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let vertexCount: Int
    let triangleCount: Int
    let frameCount: Int
    let coveredAngles: Set<ScanAngle>
    let byteCount: Int
    let isSample: Bool

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, vertexCount, triangleCount, frameCount, coveredAngles, byteCount, isSample
    }

    init(id: UUID, createdAt: Date, vertexCount: Int, triangleCount: Int,
         frameCount: Int, coveredAngles: Set<ScanAngle>, byteCount: Int, isSample: Bool) {
        self.id = id
        self.createdAt = createdAt
        self.vertexCount = vertexCount
        self.triangleCount = triangleCount
        self.frameCount = frameCount
        self.coveredAngles = coveredAngles
        self.byteCount = byteCount
        self.isSample = isSample
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        vertexCount = try values.decode(Int.self, forKey: .vertexCount)
        triangleCount = try values.decode(Int.self, forKey: .triangleCount)
        frameCount = try values.decode(Int.self, forKey: .frameCount)
        byteCount = try values.decode(Int.self, forKey: .byteCount)
        isSample = try values.decode(Bool.self, forKey: .isSample)
        let names = try values.decode([String].self, forKey: .coveredAngles)
        let angles = names.compactMap(ScanAngle.init(rawValue:))
        guard angles.count == names.count, Set(angles).count == names.count else {
            throw DecodingError.dataCorruptedError(forKey: .coveredAngles, in: values,
                                                   debugDescription: "Invalid scan coverage.")
        }
        coveredAngles = Set(angles)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(vertexCount, forKey: .vertexCount)
        try values.encode(triangleCount, forKey: .triangleCount)
        try values.encode(frameCount, forKey: .frameCount)
        try values.encode(coveredAngles.map(\.rawValue).sorted(), forKey: .coveredAngles)
        try values.encode(byteCount, forKey: .byteCount)
        try values.encode(isSample, forKey: .isSample)
    }
}

/// One actor serializes disk work. A scan is committed by a same-volume directory
/// rename only after its complete payload and metadata have been written. No
/// count-based eviction is performed: originals remain until explicitly removed.
actor ScanHistoryRepository {
    enum HistoryError: LocalizedError, Equatable {
        case notOriginal
        case invalidGeometry
        case damagedRecord
        case missingRecord

        var errorDescription: String? {
            switch self {
            case .notOriginal: "历史记录只能保存未经处理的原始扫描。"
            case .invalidGeometry: "原始扫描数据无效，无法保存历史记录。"
            case .damagedRecord: "这份历史记录不完整或已损坏，无法打开。"
            case .missingRecord: "这份历史记录已不存在。"
            }
        }
    }

    private struct Metadata: Codable {
        let version: Int
        let entry: ScanHistoryEntry
        let checksum: String
    }

    private static let formatVersion = 1
    private static let magic = Data("FSHIST01".utf8)
    private static let headerByteCount = 20
    private static let maximumVertices = 500_000
    private static let maximumTriangles = 1_000_000
    private static let maximumMetadataBytes = 64 * 1_024
    private static let maximumThumbnailBytes = 2 * 1_024 * 1_024
    private let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        self.directory = directory ?? support.appendingPathComponent("ScanHistory", isDirectory: true)
    }

    func list() throws -> [ScanHistoryEntry] {
        try Task.checkCancellation()
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let children = try fileManager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
        var entries: [ScanHistoryEntry] = []
        for (index, child) in children.enumerated() {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            // Staging directories and unrelated files never become list items.
            guard let id = UUID(uuidString: child.lastPathComponent),
                  let metadata = try? readMetadata(id: id) else { continue }
            entries.append(metadata.entry)
        }
        return entries.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
    }

    func save(_ mesh: ScanMesh, id: UUID, createdAt: Date = Date()) throws -> ScanHistoryEntry {
        try Task.checkCancellation()
        guard !mesh.isFiltered, mesh.filterSettings == nil else { throw HistoryError.notOriginal }
        try validate(mesh)
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else { throw HistoryError.invalidGeometry }
        let destination = recordDirectory(id)
        if fileManager.fileExists(atPath: destination.path) {
            // A completion retry or a view lifecycle event must not replace the
            // original or generate another entry, including across relaunches.
            return try readMetadata(id: id).entry
        }
        try prepareDirectory(directory)
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try prepareDirectory(staging)
        defer { try? fileManager.removeItem(at: staging) }

        let data = try encode(mesh)
        let entry = ScanHistoryEntry(id: id, createdAt: createdAt, vertexCount: mesh.vertexCount,
            triangleCount: mesh.triangleIndices.count / 3, frameCount: mesh.frameCount,
            coveredAngles: mesh.coveredAngles, byteCount: data.count, isSample: mesh.isSample)
        let metadata = Metadata(version: Self.formatVersion, entry: entry, checksum: Self.checksum(data))
        let metadataData = try JSONEncoder().encode(metadata)
        try write(data, to: staging.appendingPathComponent("points.bin"))
        try Task.checkCancellation()
        try write(metadataData, to: staging.appendingPathComponent("metadata.json"))
        try Task.checkCancellation()
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            // Another repository instance may already have committed this scan.
            if let existing = try? readMetadata(id: id) { return existing.entry }
            throw error
        }
        // Cancellation after the atomic commit does not undo a saved original.
        return entry
    }

    func load(_ entry: ScanHistoryEntry) throws -> ScanMesh {
        try Task.checkCancellation()
        let metadata = try readMetadata(id: entry.id)
        let data = try readLimitedFile(recordDirectory(entry.id).appendingPathComponent("points.bin"),
                                       maximumBytes: metadata.entry.byteCount)
        guard data.count == metadata.entry.byteCount, Self.checksum(data) == metadata.checksum else {
            throw HistoryError.damagedRecord
        }
        return try decode(data, entry: metadata.entry)
    }

    /// Previews are disposable derived data. Old records acquire a thumbnail
    /// only when requested; neither the original payload nor its metadata is
    /// rewritten. Running on this actor serializes generation with deletion.
    func thumbnail(for entry: ScanHistoryEntry) throws -> Data {
        try Task.checkCancellation()
        _ = try readMetadata(id: entry.id)
        let cache = recordDirectory(entry.id).appendingPathComponent("thumbnail-v1.png")
        if let data = try? readLimitedFile(cache, maximumBytes: Self.maximumThumbnailBytes),
           ScanHistoryThumbnailRenderer.isValidCache(data) {
            try Task.checkCancellation()
            return data
        }
        let original = try load(entry)
        let data = try ScanHistoryThumbnailRenderer.render(original)
        try Task.checkCancellation()
        guard data.count <= Self.maximumThumbnailBytes, ScanHistoryThumbnailRenderer.isValidCache(data) else {
            throw HistoryError.damagedRecord
        }
        // A second repository instance may have deleted this record. Never
        // recreate a directory merely to store its optional image cache.
        _ = try readMetadata(id: entry.id)
        do {
            try write(data, to: cache)
        } catch {
            // A full disk or unwritable cache must not lose the raw history or
            // prevent showing an already rendered, valid in-memory preview.
        }
        return data
    }

    func delete(_ entry: ScanHistoryEntry) throws {
        try Task.checkCancellation()
        let url = recordDirectory(entry.id)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    func deleteAll() throws {
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
    }

    private func recordDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func prepareDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        var localURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try localURL.setResourceValues(values)
        #if os(iOS) || os(tvOS) || os(watchOS)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: url.path)
        #endif
    }

    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS) || os(tvOS) || os(watchOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private func readMetadata(id: UUID) throws -> Metadata {
        let folder = recordDirectory(id)
        guard fileManager.fileExists(atPath: folder.path) else { throw HistoryError.missingRecord }
        let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true else {
            throw HistoryError.damagedRecord
        }
        do {
            let data = try readLimitedFile(folder.appendingPathComponent("metadata.json"),
                                           maximumBytes: Self.maximumMetadataBytes)
            let metadata = try JSONDecoder().decode(Metadata.self, from: data)
            let entry = metadata.entry
            guard metadata.version == Self.formatVersion, entry.id == id,
                  entry.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  (1...Self.maximumVertices).contains(entry.vertexCount),
                  (0...Self.maximumTriangles).contains(entry.triangleCount), entry.frameCount >= 0,
                  entry.byteCount == Self.headerByteCount + entry.vertexCount * 24 + entry.triangleCount * 12,
                  metadata.checksum.count == 64,
                  metadata.checksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw HistoryError.damagedRecord
            }
            let payload = folder.appendingPathComponent("points.bin")
            let values = try payload.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize == entry.byteCount else { throw HistoryError.damagedRecord }
            return metadata
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HistoryError.damagedRecord
        }
    }

    private func readLimitedFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, size <= maximumBytes else { throw HistoryError.damagedRecord }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var output = Data()
        output.reserveCapacity(size)
        while true {
            try Task.checkCancellation()
            let limit = min(1_024 * 1_024, maximumBytes - output.count + 1)
            guard let chunk = try handle.read(upToCount: limit), !chunk.isEmpty else { break }
            guard chunk.count <= maximumBytes - output.count else { throw HistoryError.damagedRecord }
            output.append(chunk)
        }
        return output
    }

    private func validate(_ mesh: ScanMesh) throws {
        guard (1...Self.maximumVertices).contains(mesh.vertexCount), mesh.frameCount >= 0,
              mesh.triangleIndices.count.isMultiple(of: 3),
              mesh.triangleIndices.count / 3 <= Self.maximumTriangles else { throw HistoryError.invalidGeometry }
        for (index, vertex) in mesh.vertices.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let p = vertex.position, c = vertex.color
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
                  c.x.isFinite, c.y.isFinite, c.z.isFinite,
                  (0...1).contains(c.x), (0...1).contains(c.y), (0...1).contains(c.z) else {
                throw HistoryError.invalidGeometry
            }
        }
        for (index, value) in mesh.triangleIndices.enumerated() {
            if index.isMultiple(of: 3_072) { try Task.checkCancellation() }
            guard value < mesh.vertexCount else { throw HistoryError.invalidGeometry }
        }
    }

    private func encode(_ mesh: ScanMesh) throws -> Data {
        var data = Self.magic
        data.reserveCapacity(Self.headerByteCount + mesh.vertexCount * 24 + mesh.triangleIndices.count * 4)
        func append(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(Self.formatVersion))
        append(UInt32(mesh.vertexCount))
        append(UInt32(mesh.triangleIndices.count))
        for (index, vertex) in mesh.vertices.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            append(vertex.position.x.bitPattern); append(vertex.position.y.bitPattern); append(vertex.position.z.bitPattern)
            append(vertex.color.x.bitPattern); append(vertex.color.y.bitPattern); append(vertex.color.z.bitPattern)
        }
        for (index, value) in mesh.triangleIndices.enumerated() {
            if index.isMultiple(of: 3_072) { try Task.checkCancellation() }
            append(value)
        }
        return data
    }

    private func decode(_ data: Data, entry: ScanHistoryEntry) throws -> ScanMesh {
        return try data.withUnsafeBytes { bytes in
            guard data.count == entry.byteCount, data.prefix(8) == Self.magic else { throw HistoryError.damagedRecord }
            var offset = 8
            func read() -> UInt32 {
                let value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                offset += 4
                return UInt32(littleEndian: value)
            }
            guard read() == Self.formatVersion, read() == entry.vertexCount,
                  read() == entry.triangleCount * 3 else { throw HistoryError.damagedRecord }
            var vertices: [ScanVertex] = []
            vertices.reserveCapacity(entry.vertexCount)
            for index in 0..<entry.vertexCount {
                if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
                let p = SIMD3(Float(bitPattern: read()), Float(bitPattern: read()), Float(bitPattern: read()))
                let c = SIMD3(Float(bitPattern: read()), Float(bitPattern: read()), Float(bitPattern: read()))
                vertices.append(ScanVertex(position: p, color: c))
            }
            var triangles: [UInt32] = []
            triangles.reserveCapacity(entry.triangleCount * 3)
            for index in 0..<(entry.triangleCount * 3) {
                if index.isMultiple(of: 3_072) { try Task.checkCancellation() }
                triangles.append(read())
            }
            let mesh = ScanMesh(vertices: vertices, triangleIndices: triangles,
                                frameCount: entry.frameCount, coveredAngles: entry.coveredAngles, isSample: entry.isSample)
            do { try validate(mesh) }
            catch is CancellationError { throw CancellationError() }
            catch { throw HistoryError.damagedRecord }
            return mesh
        }
    }

    private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

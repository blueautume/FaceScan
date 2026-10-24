import Foundation

/// Imported files retain their original coordinates and are displayed as a
/// point cloud. A generic PLY never implies that FaceScan measured a real face.
struct PLYDocument: Sendable {
    let mesh: ScanMesh
    let filename: String
}

enum PLYImporter {
    static let maximumFileBytes = 64 * 1_024 * 1_024
    static let maximumVertices = 500_000
    private static let maximumHeaderBytes = 128 * 1_024
    private static let maximumFaces = 500_000
    private static let maximumRecords = 1_000_000
    private static let maximumListLength = 4_096
    private static let maximumListItems = 4_000_000
    private static let maximumTriangles = 1_000_000

    enum ImportError: LocalizedError, Equatable {
        case invalidHeader
        case unsupportedFormat
        case fileTooLarge
        case tooManyVertices
        case tooComplex
        case truncated
        case invalidValue
        case invalidGeometry
        case unreadableFile

        var errorDescription: String? {
            switch self {
            case .invalidHeader: "PLY 文件头无效或缺少顶点坐标。"
            case .unsupportedFormat: "仅支持 PLY 1.0 的 ASCII、二进制小端和二进制大端格式。"
            case .fileTooLarge: "PLY 文件不能超过 64 MB。"
            case .tooManyVertices: "PLY 文件最多支持 50 万个顶点。"
            case .tooComplex: "PLY 文件的面或属性数据过于复杂，无法安全打开。"
            case .truncated: "PLY 文件不完整，无法读取。"
            case .invalidValue: "PLY 文件包含无效数值、颜色或额外数据。"
            case .invalidGeometry: "PLY 文件包含无效坐标或面索引。"
            case .unreadableFile: "无法读取这个 PLY 文件。"
            }
        }
    }

    /// File-provider access, coordination, disk reading, and parsing all run
    /// outside the main actor. Cancellation propagates to the detached worker.
    /// No copy is saved in the app and the source file is never modified.
    static func load(from url: URL) async throws -> PLYDocument {
        try Task.checkCancellation()
        guard url.isFileURL else { throw ImportError.unreadableFile }
        let worker = Task.detached(priority: .userInitiated) {
            try readCoordinatedFile(at: url)
        }
        return try await withTaskCancellationHandler {
            let document = try await worker.value
            try Task.checkCancellation()
            return document
        } onCancel: {
            worker.cancel()
        }
    }

    /// Also exposed separately so format validation can be tested without any
    /// document-provider or UI dependencies. Call off the main actor for files.
    static func parse(_ data: Data, filename: String = "模型.ply") throws -> PLYDocument {
        try Task.checkCancellation()
        guard data.count <= maximumFileBytes else { throw ImportError.fileTooLarge }
        return try data.withUnsafeBytes { bytes in
            var reader = Reader(bytes: bytes)
            let header = try readHeader(&reader)
            reader.format = header.format
            var vertices: [ScanVertex] = []
            vertices.reserveCapacity(header.vertexCount)
            var triangles: [UInt32] = []
            var listItemCount = 0
            var recordCount = 0

            for element in header.elements {
                for _ in 0..<element.count {
                    if recordCount.isMultiple(of: 512) { try Task.checkCancellation() }
                    recordCount += 1
                    var position = SIMD3<Float>(repeating: 0)
                    var color = SIMD3<Float>(repeating: 0.78)
                    var polygon: [UInt32]?
                    for property in element.properties {
                        switch property.kind {
                        case let .scalar(type):
                            let value = try reader.scalar(type)
                            if element.name == "vertex" {
                                switch property.name {
                                case "x", "y", "z":
                                    let coordinate = Float(value)
                                    guard coordinate.isFinite else { throw ImportError.invalidGeometry }
                                    position[property.name == "x" ? 0 : property.name == "y" ? 1 : 2] = coordinate
                                case "red", "green", "blue", "alpha":
                                    let normalized = try colorComponent(value, type: type)
                                    // ScanVertex stores RGB. Alpha is validated
                                    // but does not hide measured/imported points.
                                    if property.name != "alpha" {
                                        color[property.name == "red" ? 0 : property.name == "green" ? 1 : 2] = normalized
                                    }
                                default: break
                                }
                            }
                        case let .list(countType, itemType):
                            let countValue = try reader.scalar(countType)
                            guard countValue >= 0, countValue <= Double(maximumListLength) else {
                                throw ImportError.tooComplex
                            }
                            let count = Int(countValue)
                            guard listItemCount <= maximumListItems - count else { throw ImportError.tooComplex }
                            listItemCount += count
                            let isIndices = element.name == "face"
                                && (property.name == "vertex_indices" || property.name == "vertex_index")
                            if isIndices {
                                guard count >= 3 else { throw ImportError.invalidGeometry }
                                guard triangles.count / 3 <= maximumTriangles - (count - 2) else {
                                    throw ImportError.tooComplex
                                }
                                polygon = []
                                polygon?.reserveCapacity(count)
                            }
                            for item in 0..<count {
                                if item.isMultiple(of: 1_024) { try Task.checkCancellation() }
                                let value = try reader.scalar(itemType)
                                if isIndices {
                                    guard value >= 0, value < Double(header.vertexCount) else {
                                        throw ImportError.invalidGeometry
                                    }
                                    polygon?.append(UInt32(value))
                                }
                            }
                        }
                    }
                    if element.name == "vertex" {
                        vertices.append(ScanVertex(position: position, color: color))
                    }
                    if let polygon {
                        // Standard fan triangulation retains ordinary triangles
                        // and convex polygons. Point-cloud viewing uses vertices;
                        // malformed/degenerate indices reject the entire file.
                        for index in 1..<(polygon.count - 1) {
                            let a = polygon[0], b = polygon[index], c = polygon[index + 1]
                            guard a != b, a != c, b != c else { throw ImportError.invalidGeometry }
                            triangles.append(contentsOf: [a, b, c])
                        }
                    }
                }
            }
            try Task.checkCancellation()
            if header.format == .ascii { reader.skipWhitespace() }
            guard reader.offset == bytes.count else { throw ImportError.invalidValue }
            return PLYDocument(mesh: ScanMesh(vertices: vertices, triangleIndices: triangles,
                                              frameCount: 0, coveredAngles: [], isSample: header.isSample),
                               filename: filename)
        }
    }

    private static func readCoordinatedFile(at url: URL) throws -> PLYDocument {
        try Task.checkCancellation()
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer { if scopedAccess { url.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<PLYDocument, Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            result = Result {
                try Task.checkCancellation()
                let values = try coordinatedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile != false else { throw ImportError.unreadableFile }
                if let size = values.fileSize, size > maximumFileBytes { throw ImportError.fileTooLarge }
                let handle = try FileHandle(forReadingFrom: coordinatedURL)
                defer { try? handle.close() }
                var data = Data()
                if let size = values.fileSize { data.reserveCapacity(min(max(size, 0), maximumFileBytes)) }
                while true {
                    try Task.checkCancellation()
                    // The extra byte detects growth or inaccurate provider size
                    // metadata without ever reading an unbounded file into RAM.
                    let limit = min(1_024 * 1_024, maximumFileBytes - data.count + 1)
                    guard let chunk = try handle.read(upToCount: limit), !chunk.isEmpty else { break }
                    guard chunk.count <= maximumFileBytes - data.count else { throw ImportError.fileTooLarge }
                    data.append(chunk)
                }
                return try parse(data, filename: url.lastPathComponent)
            }
        }
        try Task.checkCancellation()
        if let result { return try result.get() }
        throw coordinationError ?? ImportError.unreadableFile as Error
    }

    private enum Format: String {
        case ascii
        case littleEndian = "binary_little_endian"
        case bigEndian = "binary_big_endian"
    }

    private enum ScalarType {
        case int8, uint8, int16, uint16, int32, uint32, float32, float64

        init?(_ name: Substring) {
            switch name {
            case "char", "int8": self = .int8
            case "uchar", "uint8": self = .uint8
            case "short", "int16": self = .int16
            case "ushort", "uint16": self = .uint16
            case "int", "int32": self = .int32
            case "uint", "uint32": self = .uint32
            case "float", "float32": self = .float32
            case "double", "float64": self = .float64
            default: return nil
            }
        }

        var isInteger: Bool { self != .float32 && self != .float64 }
        var byteCount: Int {
            switch self {
            case .int8, .uint8: 1
            case .int16, .uint16: 2
            case .int32, .uint32, .float32: 4
            case .float64: 8
            }
        }
        var integerRange: ClosedRange<Double>? {
            switch self {
            case .int8: Double(Int8.min)...Double(Int8.max)
            case .uint8: 0...Double(UInt8.max)
            case .int16: Double(Int16.min)...Double(Int16.max)
            case .uint16: 0...Double(UInt16.max)
            case .int32: Double(Int32.min)...Double(Int32.max)
            case .uint32: 0...Double(UInt32.max)
            case .float32, .float64: nil
            }
        }
    }

    private struct Property {
        enum Kind {
            case scalar(ScalarType)
            case list(ScalarType, ScalarType)
        }
        let name: String
        let kind: Kind
    }

    private struct Element {
        let name: String
        let count: Int
        var properties: [Property] = []
    }

    private struct Header {
        let format: Format
        let elements: [Element]
        let vertexCount: Int
        let isSample: Bool
    }

    private static func readHeader(_ reader: inout Reader) throws -> Header {
        guard try reader.headerLine() == "ply" else { throw ImportError.invalidHeader }
        var format: Format?
        var elements: [Element] = []
        var isSample = false
        var totalRecords = 0
        while true {
            try Task.checkCancellation()
            let line = try reader.headerLine()
            let words = line.split(whereSeparator: \.isWhitespace)
            guard let directive = words.first else { continue }
            switch directive {
            case "format":
                guard format == nil, elements.isEmpty, words.count == 3,
                      words[2] == "1.0", let parsed = Format(rawValue: String(words[1])) else {
                    throw ImportError.unsupportedFormat
                }
                format = parsed
            case "comment", "obj_info":
                if directive == "comment", line.lowercased().contains("synthetic sample - not a real scan") {
                    isSample = true
                }
            case "element":
                guard format != nil, words.count == 3, let count = Int(words[2]), count >= 0,
                      !elements.contains(where: { $0.name == words[1] }) else { throw ImportError.invalidHeader }
                if words[1] == "vertex", count > maximumVertices { throw ImportError.tooManyVertices }
                guard elements.count < 64, count <= maximumRecords,
                      totalRecords <= maximumRecords - count else { throw ImportError.tooComplex }
                if words[1] == "face", count > maximumFaces { throw ImportError.tooComplex }
                totalRecords += count
                elements.append(Element(name: String(words[1]), count: count))
            case "property":
                guard !elements.isEmpty, elements[elements.count - 1].properties.count < 64 else {
                    throw ImportError.invalidHeader
                }
                let property: Property
                if words.count == 3, let type = ScalarType(words[1]) {
                    property = Property(name: String(words[2]), kind: .scalar(type))
                } else if words.count == 5, words[1] == "list",
                          let countType = ScalarType(words[2]), countType.isInteger,
                          let itemType = ScalarType(words[3]) {
                    property = Property(name: String(words[4]), kind: .list(countType, itemType))
                } else { throw ImportError.invalidHeader }
                guard !elements[elements.count - 1].properties.contains(where: { $0.name == property.name }) else {
                    throw ImportError.invalidHeader
                }
                elements[elements.count - 1].properties.append(property)
            case "end_header":
                guard words.count == 1, let format,
                      let vertex = elements.first(where: { $0.name == "vertex" }), vertex.count > 0 else {
                    throw ImportError.invalidHeader
                }
                for name in ["x", "y", "z"] {
                    guard let property = vertex.properties.first(where: { $0.name == name }),
                          case .scalar = property.kind else { throw ImportError.invalidHeader }
                }
                let rgb = vertex.properties.filter { ["red", "green", "blue"].contains($0.name) }
                guard rgb.isEmpty || rgb.count == 3 else { throw ImportError.invalidHeader }
                for property in vertex.properties where ["red", "green", "blue", "alpha"].contains(property.name) {
                    guard case .scalar = property.kind else { throw ImportError.invalidHeader }
                }
                for element in elements {
                    guard element.count == 0 || !element.properties.isEmpty else { throw ImportError.invalidHeader }
                    if element.name == "face" {
                        let indexProperties = element.properties.filter {
                            $0.name == "vertex_indices" || $0.name == "vertex_index"
                        }
                        guard indexProperties.count <= 1 else { throw ImportError.invalidHeader }
                        for property in indexProperties {
                            guard case let .list(_, type) = property.kind, type.isInteger else {
                                throw ImportError.invalidHeader
                            }
                        }
                    }
                }
                return Header(format: format, elements: elements, vertexCount: vertex.count, isSample: isSample)
            default: throw ImportError.invalidHeader
            }
        }
    }

    private static func colorComponent(_ value: Double, type: ScalarType) throws -> Float {
        // Standard PLY RGB is uchar; normalized floating-point RGB and ushort
        // RGB are common extensions. Other integer declarations use byte RGB.
        let maximum: Double = type == .uint16 ? 65_535 : type.isInteger ? 255 : 1
        guard value >= 0, value <= maximum else { throw ImportError.invalidValue }
        return Float(value / maximum)
    }

    private struct Reader {
        let bytes: UnsafeRawBufferPointer
        var offset = 0
        var format = Format.ascii

        mutating func headerLine() throws -> String {
            guard offset < bytes.count, offset < maximumHeaderBytes else { throw ImportError.invalidHeader }
            let start = offset
            while offset < bytes.count, bytes[offset] != 10, bytes[offset] != 13 {
                offset += 1
                guard offset <= maximumHeaderBytes else { throw ImportError.invalidHeader }
            }
            guard let line = String(bytes: bytes[start..<offset], encoding: .ascii) else {
                throw ImportError.invalidHeader
            }
            if offset < bytes.count {
                let terminator = bytes[offset]
                offset += 1
                if terminator == 13, offset < bytes.count, bytes[offset] == 10 { offset += 1 }
            }
            return line
        }

        mutating func skipWhitespace() {
            while offset < bytes.count, Self.isWhitespace(bytes[offset]) { offset += 1 }
        }

        private static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 32 || (9...13).contains(byte)
        }

        mutating func scalar(_ type: ScalarType) throws -> Double {
            let value: Double
            if format == .ascii {
                skipWhitespace()
                guard offset < bytes.count else { throw ImportError.truncated }
                let start = offset
                while offset < bytes.count, !Self.isWhitespace(bytes[offset]) {
                    offset += 1
                    guard offset - start <= 128 else { throw ImportError.invalidValue }
                }
                guard let token = String(bytes: bytes[start..<offset], encoding: .ascii) else {
                    throw ImportError.invalidValue
                }
                if let range = type.integerRange {
                    guard let integer = Int64(token), range.contains(Double(integer)) else {
                        throw ImportError.invalidValue
                    }
                    value = Double(integer)
                } else {
                    // Swift's Double parser also accepts hexadecimal notation,
                    // which is outside the decimal PLY ASCII number grammar.
                    guard token.utf8.allSatisfy({
                        (48...57).contains($0) || $0 == 43 || $0 == 45 || $0 == 46 || $0 == 69 || $0 == 101
                    }), let number = Double(token) else { throw ImportError.invalidValue }
                    value = number
                }
            } else {
                let width = type.byteCount
                guard offset <= bytes.count - width else { throw ImportError.truncated }
                var bits: UInt64 = 0
                for index in 0..<width {
                    let shift = format == .littleEndian ? index * 8 : (width - index - 1) * 8
                    bits |= UInt64(bytes[offset + index]) << shift
                }
                offset += width
                switch type {
                case .int8: value = Double(Int8(bitPattern: UInt8(bits)))
                case .uint8: value = Double(bits)
                case .int16: value = Double(Int16(bitPattern: UInt16(bits)))
                case .uint16: value = Double(bits)
                case .int32: value = Double(Int32(bitPattern: UInt32(bits)))
                case .uint32: value = Double(bits)
                case .float32: value = Double(Float(bitPattern: UInt32(bits)))
                case .float64: value = Double(bitPattern: bits)
                }
            }
            guard value.isFinite, type != .float32 || Float(value).isFinite else { throw ImportError.invalidValue }
            return value
        }
    }
}

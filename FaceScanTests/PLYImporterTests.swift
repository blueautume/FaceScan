import Foundation
import XCTest
@testable import FaceScan

final class PLYImporterTests: XCTestCase {
    func testASCIIUsesDeclaredPropertyOrderAndSkipsExtraVertexProperties() throws {
        let data = ascii("""
        ply
        format ascii 1.0
        element vertex 1
        property uchar blue
        property double y
        property float intensity
        property float x
        property float z
        property uchar red
        property uchar green
        property uchar alpha
        end_header
        128 -2.5 0.25 1.25 3.75 255 0 255
        """)

        let document = try PLYImporter.parse(data, filename: "外部模型.ply")

        XCTAssertEqual(document.filename, "外部模型.ply")
        XCTAssertEqual(document.mesh.vertexCount, 1)
        XCTAssertEqual(document.mesh.vertices[0].position, SIMD3(1.25, -2.5, 3.75))
        XCTAssertEqual(document.mesh.vertices[0].color.x, 1)
        XCTAssertEqual(document.mesh.vertices[0].color.y, 0)
        XCTAssertEqual(document.mesh.vertices[0].color.z, 128 / 255, accuracy: 0.00001)
        XCTAssertFalse(document.mesh.isSample)
        XCTAssertEqual(document.mesh.frameCount, 0)
        XCTAssertEqual(document.mesh.coveredAngles, [])
    }

    func testUncoloredPointsHaveVisibleDefaultColorAndKeepOriginalCoordinates() throws {
        let mesh = try PLYImporter.parse(pointFile("10000 -20000 30000")).mesh
        XCTAssertEqual(mesh.vertices[0].position, SIMD3(10_000, -20_000, 30_000))
        XCTAssertEqual(mesh.vertices[0].color, SIMD3(repeating: 0.78))
        XCTAssertTrue(mesh.triangleIndices.isEmpty)
    }

    func testFloatingPointAndUInt16ColorsAreNormalizedAndAlphaDoesNotHidePoints() throws {
        for (type, colors) in [("float", "1 0 0.5 0"), ("ushort", "65535 0 32768 0")] {
            let document = try PLYImporter.parse(pointFile("0 1 2 \(colors)", extraProperties: """
            property \(type) red
            property \(type) green
            property \(type) blue
            property \(type) alpha
            """))
            XCTAssertEqual(document.mesh.vertexCount, 1)
            XCTAssertEqual(document.mesh.vertices[0].color.x, 1)
            XCTAssertEqual(document.mesh.vertices[0].color.y, 0)
            XCTAssertEqual(document.mesh.vertices[0].color.z, 0.5, accuracy: 0.00002)
        }
    }

    func testUnknownElementsAndListsAreConsumedWithoutChangingPointData() throws {
        let data = ascii("""
        ply
        format ascii 1.0
        obj_info external point cloud
        element metadata 1
        property list ushort double values
        property int32 id
        element vertex 1
        property float32 x
        property float32 y
        property float32 z
        property list uint8 int8 neighborhood
        element material 1
        property uint32 code
        end_header
        3 0.5 -1 2 42
        1 2 3 2 -1 127
        4294967295
        """)
        let mesh = try PLYImporter.parse(data).mesh
        XCTAssertEqual(mesh.vertexCount, 1)
        XCTAssertEqual(mesh.vertices[0].position, SIMD3(1, 2, 3))
    }

    func testFacesMayPrecedeVerticesAndPolygonsUseFanTriangulation() throws {
        let data = ascii("""
        ply
        format ascii 1.0
        element face 1
        property uchar material
        property list uchar uint vertex_index
        element vertex 4
        property float x
        property float y
        property float z
        end_header
        5 4 0 1 2 3
        0 0 0
        1 0 0
        1 1 0
        0 1 0
        """)
        XCTAssertEqual(try PLYImporter.parse(data).mesh.triangleIndices, [0, 1, 2, 0, 2, 3])
    }

    func testLittleAndBigEndianBinaryPointsFacesAndScalarAliases() throws {
        for littleEndian in [true, false] {
            let mesh = try PLYImporter.parse(binaryFixture(littleEndian: littleEndian)).mesh
            XCTAssertEqual(mesh.vertexCount, 3)
            XCTAssertEqual(mesh.vertices[0].position, SIMD3(1.5, -2.25, 0.125))
            XCTAssertEqual(mesh.vertices[1].position, SIMD3(2.5, -1.25, 1.125))
            XCTAssertEqual(mesh.vertices[2].position, SIMD3(3.5, -0.25, 2.125))
            XCTAssertEqual(mesh.vertices[0].color, SIMD3(1, 0, 128 / 255))
            XCTAssertEqual(mesh.triangleIndices, [0, 1, 2])
        }
    }

    func testCRLFAndLegacyCRLineEndingsAreAccepted() throws {
        for ending in ["\r\n", "\r"] {
            let data = Data(String(decoding: pointFile("0 1 2"), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: ending).utf8)
            XCTAssertEqual(try PLYImporter.parse(data).mesh.vertexCount, 1)
        }
    }

    func testSyntheticSampleCommentIsPreservedButGenericFilesAreNotMarkedMeasured() throws {
        let sample = String(decoding: pointFile("0 1 2"), as: UTF8.self)
            .replacingOccurrences(of: "format ascii 1.0", with: """
            format ascii 1.0
            comment FaceScan synthetic sample - not a real scan
            comment accepted_depth_frames 99
            """)
        let mesh = try PLYImporter.parse(Data(sample.utf8)).mesh
        XCTAssertTrue(mesh.isSample)
        XCTAssertEqual(mesh.frameCount, 0)
        XCTAssertTrue(mesh.coveredAngles.isEmpty)
    }

    func testExporterRoundTripKeepsGeometryColorsAndSyntheticIdentity() throws {
        let original = ScanMesh(vertices: [
            ScanVertex(position: SIMD3(0.1, 0.2, 0.3), color: SIMD3(1, 0, 0.5)),
            ScanVertex(position: SIMD3(0.2, 0.2, 0.3), color: SIMD3(0, 1, 0)),
            ScanVertex(position: SIMD3(0.1, 0.3, 0.3), color: SIMD3(0, 0, 1))
        ], triangleIndices: [0, 1, 2], frameCount: 8, coveredAngles: [.center], isSample: true)
        let url = try ScanExporter.export(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try PLYImporter.parse(Data(contentsOf: url)).mesh

        XCTAssertEqual(imported.vertices.map(\.position), original.vertices.map(\.position))
        XCTAssertEqual(imported.triangleIndices, original.triangleIndices)
        XCTAssertEqual(imported.vertices[0].color.z, 128 / 255, accuracy: 0.00001)
        XCTAssertTrue(imported.isSample)
    }

    func testInvalidHeadersAreRejected() {
        let valid = String(decoding: pointFile("0 1 2"), as: UTF8.self)
        let invalid = [
            valid.replacingOccurrences(of: "ply\n", with: "obj\n"),
            valid.replacingOccurrences(of: "format ascii 1.0\n", with: ""),
            valid.replacingOccurrences(of: "property float z", with: "property float x"),
            valid.replacingOccurrences(of: "property float z\n", with: ""),
            valid.replacingOccurrences(of: "property float x", with: "property list uchar float x"),
            valid.replacingOccurrences(of: "property float x", with: "property int64 x"),
            valid.replacingOccurrences(of: "element vertex 1", with: "element vertex 0"),
            valid.replacingOccurrences(of: "element vertex 1", with: "element vertex -1"),
            valid.replacingOccurrences(of: "element vertex 1", with: "element vertex 999999999999999999999999"),
            valid.replacingOccurrences(of: "end_header", with: "property list float int values\nend_header"),
            valid.replacingOccurrences(of: "end_header", with: "property uchar red\nend_header"),
            valid.replacingOccurrences(of: "end_header", with: "element vertex 1\nend_header")
        ]
        for text in invalid {
            assertError(.invalidHeader, data: Data(text.utf8))
        }
    }

    func testUnsupportedFormatAndVersionHaveSpecificError() {
        let valid = String(decoding: pointFile("0 1 2"), as: UTF8.self)
        for format in ["ascii 2.0", "compressed 1.0", "binary_middle_endian 1.0"] {
            assertError(.unsupportedFormat, data: Data(valid.replacingOccurrences(of: "ascii 1.0", with: format).utf8))
        }
    }

    func testExcessiveDeclaredCountsAreRejectedBeforeAllocation() {
        let valid = String(decoding: pointFile("0 1 2"), as: UTF8.self)
        assertError(.tooManyVertices, data: Data(valid.replacingOccurrences(of: "vertex 1", with: "vertex 500001").utf8))
        assertError(.tooComplex, data: Data(valid.replacingOccurrences(of: "end_header", with: """
        element face 500001
        property list uchar uint vertex_indices
        end_header
        """).utf8))
        assertError(.tooComplex, data: Data(valid.replacingOccurrences(of: "end_header", with: """
        element unknown 1000000
        property int id
        end_header
        """).utf8))
    }

    func testOversizedFileIsRejectedBeforeParsing() {
        assertError(.fileTooLarge, data: Data(count: PLYImporter.maximumFileBytes + 1))
    }

    func testNonFiniteOverflowingAndMalformedScalarsAreRejected() {
        for value in ["nan", "inf", "-inf", "1e1000", "1e100", "hello", "0x123", String(repeating: "9", count: 129)] {
            assertError(.invalidValue, data: pointFile("\(value) 0 0"))
        }
        for value in ["256", "-1", "1.5", "999999999999999999999"] {
            assertError(.invalidValue, data: pointFile("0 0 0 \(value)", extraProperties: "property uchar intensity"))
        }
        assertError(.invalidGeometry, data: pointFile("1e100 0 0", coordinateType: "double"))
    }

    func testInvalidColorsAndAlphaAreRejected() {
        for (type, color) in [("uchar", "256 0 0 255"), ("float", "1.01 0 0 1"),
                              ("float", "1 0 0 -0.1"), ("int", "-1 0 0 255")] {
            assertError(.invalidValue, data: pointFile("0 0 0 \(color)", extraProperties: """
            property \(type) red
            property \(type) green
            property \(type) blue
            property \(type) alpha
            """))
        }
    }

    func testMalformedOrOutOfRangeFacesRejectEntireFile() {
        for face in ["3 0 1 3", "3 -1 1 2", "3 0 0 2", "2 0 1"] {
            assertError(.invalidGeometry, data: triangleFile(face))
        }
        let floatingIndices = String(decoding: triangleFile("3 0 1 2"), as: UTF8.self)
            .replacingOccurrences(of: "list uchar int vertex_indices", with: "list uchar float vertex_indices")
        assertError(.invalidHeader, data: Data(floatingIndices.utf8))
    }

    func testNegativeOrExcessiveListsRejectBeforeReadingItems() {
        for count in ["-1", "4097", "2147483647"] {
            assertError(.tooComplex, data: pointFile("0 0 0 \(count)", extraProperties: "property list int float neighbors"))
        }
    }

    func testTruncatedASCIIAndEveryTruncatedBinaryPayloadAreRejected() {
        assertError(.truncated, data: pointFile("0 1"))
        let binary = binaryFixture(littleEndian: true)
        let marker = Data("end_header\n".utf8)
        let bodyStart = binary.range(of: marker)!.upperBound
        for length in bodyStart..<binary.count {
            XCTAssertThrowsError(try PLYImporter.parse(Data(binary.prefix(length)))) { error in
                XCTAssertEqual(error as? PLYImporter.ImportError, .truncated)
            }
        }
    }

    func testUnexpectedTrailingASCIIAndBinaryPayloadAreRejected() {
        var asciiFile = pointFile("0 1 2")
        asciiFile.append(Data("0".utf8))
        assertError(.invalidValue, data: asciiFile)
        var binary = binaryFixture(littleEndian: false)
        binary.append(0)
        assertError(.invalidValue, data: binary)
    }

    func testCoordinatedURLLoadingKeepsFilenameAndNeverChangesSource() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PLY读取-\(UUID().uuidString).ply")
        let contents = pointFile("100 200 300")
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await PLYImporter.load(from: url)

        XCTAssertEqual(document.filename, url.lastPathComponent)
        XCTAssertEqual(document.mesh.vertices[0].position, SIMD3(100, 200, 300))
        XCTAssertEqual(try Data(contentsOf: url), contents)
    }

    func testAlreadyCancelledParsingAndLoadingThrowCancellation() async {
        let data = pointFile("0 1 2")
        let parsing = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PLYImporter.parse(data)
        }
        let loading = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PLYImporter.load(from: URL(fileURLWithPath: "/nonexistent.ply"))
        }
        for task in [parsing, loading] {
            do {
                _ = try await task.value
                XCTFail("Cancelled import must not return a model")
            } catch is CancellationError {
                // Cancellation takes precedence over parsing or file access.
            } catch {
                XCTFail("Expected CancellationError, received \(error)")
            }
        }
    }

    private func ascii(_ text: String) -> Data { Data((text + "\n").utf8) }

    private func pointFile(_ body: String, coordinateType: String = "float", extraProperties: String = "") -> Data {
        ascii("""
        ply
        format ascii 1.0
        element vertex 1
        property \(coordinateType) x
        property \(coordinateType) y
        property \(coordinateType) z
        \(extraProperties)
        end_header
        \(body)
        """)
    }

    private func triangleFile(_ face: String) -> Data {
        ascii("""
        ply
        format ascii 1.0
        element vertex 3
        property float x
        property float y
        property float z
        element face 1
        property list uchar int vertex_indices
        end_header
        0 0 0
        1 0 0
        0 1 0
        \(face)
        """)
    }

    private func binaryFixture(littleEndian: Bool) -> Data {
        var data = ascii("""
        ply
        format \(littleEndian ? "binary_little_endian" : "binary_big_endian") 1.0
        element metadata 1
        property int8 signed_byte
        property uint8 unsigned_byte
        property int16 signed_short
        property uint16 unsigned_short
        property int32 signed_int
        property uint32 unsigned_int
        property float32 float_value
        property float64 double_value
        property list ushort short values
        element vertex 3
        property double z
        property float x
        property float y
        property uchar red
        property uchar green
        property uchar blue
        element face 1
        property list ushort int16 vertex_indices
        end_header
        """)
        func append(_ bits: UInt64, width: Int) {
            for index in 0..<width {
                let shift = littleEndian ? index * 8 : (width - index - 1) * 8
                data.append(UInt8(truncatingIfNeeded: bits >> shift))
            }
        }
        append(UInt64(UInt8(bitPattern: -128)), width: 1)
        append(255, width: 1)
        append(UInt64(UInt16(bitPattern: -32_768)), width: 2)
        append(65_535, width: 2)
        append(UInt64(UInt32(bitPattern: Int32.min)), width: 4)
        append(UInt64(UInt32.max), width: 4)
        append(UInt64(Float(-0.125).bitPattern), width: 4)
        append(Double(1.25).bitPattern, width: 8)
        append(2, width: 2)
        append(UInt64(UInt16(bitPattern: -2)), width: 2)
        append(32_767, width: 2)
        for index in 0..<3 {
            append((Double(index) + 0.125).bitPattern, width: 8)
            append(UInt64((Float(index) + 1.5).bitPattern), width: 4)
            append(UInt64((Float(index) - 2.25).bitPattern), width: 4)
            append(255, width: 1)
            append(0, width: 1)
            append(128, width: 1)
        }
        append(3, width: 2)
        for index in 0..<3 { append(UInt64(index), width: 2) }
        return data
    }

    private func assertError(_ expected: PLYImporter.ImportError, data: Data,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PLYImporter.parse(data), file: file, line: line) { error in
            XCTAssertEqual(error as? PLYImporter.ImportError, expected, file: file, line: line)
        }
    }
}

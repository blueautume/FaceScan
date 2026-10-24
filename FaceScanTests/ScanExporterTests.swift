import Foundation
import XCTest
@testable import FaceScan

final class ScanExporterTests: XCTestCase {
    func testPLYContainsMeterCoordinatesVertexColorsAndFaces() throws {
        let url = try ScanExporter.export(triangleFixture())
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(url.pathExtension, "ply")
        XCTAssertTrue(text.hasPrefix("ply\nformat ascii 1.0\n"))
        XCTAssertTrue(text.contains("comment coordinate_units meters\n"))
        XCTAssertTrue(text.contains("element vertex 3\n"))
        XCTAssertTrue(text.contains("property uchar red\nproperty uchar green\nproperty uchar blue\n"))
        XCTAssertTrue(text.contains("element face 1\nproperty list uchar uint vertex_indices\n"))
        XCTAssertTrue(text.contains("comment accepted_depth_frames 8\n"))
        XCTAssertTrue(text.contains("comment captured_views center\n"))
        XCTAssertTrue(text.contains("comment view_coverage 1/7\n"))
        let body = try XCTUnwrap(text.components(separatedBy: "end_header\n").last)
        let lines = body.split(separator: "\n")
        XCTAssertEqual(lines.count, 4)
        let first = lines[0].split(separator: " ")
        // Coordinates are retained verbatim in meters, with no display scaling.
        XCTAssertEqual(try XCTUnwrap(Float(first[0])), 0.01, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(Float(first[1])), 0.02, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(Float(first[2])), 0.03, accuracy: 0.000001)
        XCTAssertEqual(Array(first.suffix(3)), ["255", "0", "128"])
        XCTAssertEqual(lines[3], "3 0 1 2")
        XCTAssertTrue(text.contains("TrueDepth measured surface"))
    }

    func testSyntheticSampleIsExplicitlyMarkedInFileAndFilename() throws {
        var mesh = triangleFixture()
        mesh.isSample = true
        let url = try ScanExporter.export(mesh)
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(url.lastPathComponent.contains("sample"))
        XCTAssertTrue(text.contains("synthetic sample - not a real scan"))
        XCTAssertFalse(text.contains("TrueDepth measured surface"))
    }

    func testEmptyMeshIsRejected() {
        let mesh = ScanMesh(vertices: [], triangleIndices: [], frameCount: 0, coveredAngles: [])
        XCTAssertThrowsError(try ScanExporter.export(mesh)) { error in
            guard case ScanExporter.ExportError.emptyMesh = error else {
                return XCTFail("Expected emptyMesh, received \(error)")
            }
        }
    }

    func testOutOfRangeTriangleIsRejected() {
        var mesh = triangleFixture()
        mesh.triangleIndices = [0, 1, 99]
        assertInvalid(mesh)
    }

    func testIncompleteTriangleIsRejected() {
        var mesh = triangleFixture()
        mesh.triangleIndices = [0, 1]
        assertInvalid(mesh)
    }

    func testNonFiniteCoordinatesAndColorsAreRejected() {
        var mesh = triangleFixture()
        mesh.vertices[0].position.x = .nan
        assertInvalid(mesh)
        mesh = triangleFixture()
        mesh.vertices[1].color.z = .infinity
        assertInvalid(mesh)
    }

    func testPointCloudWithoutTrianglesCanStillBeExported() throws {
        var mesh = triangleFixture()
        mesh.triangleIndices = []
        let url = try ScanExporter.export(mesh)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("element face 0\n"))
    }

    func testAlreadyCancelledTaskCreatesNoExportFiles() async throws {
        ScanExporter.removeTemporaryExports()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceScanExports", isDirectory: true)
        let mesh = triangleFixture()
        let exportTask = Task.detached { () throws -> URL in
            // Enter the exporter in a known cancelled state, independently of
            // scheduler timing or how quickly this small fixture can be saved.
            withUnsafeCurrentTask { $0?.cancel() }
            return try ScanExporter.export(mesh)
        }

        do {
            _ = try await exportTask.value
            XCTFail("A cancelled export must not return a file")
        } catch is CancellationError {
            // Expected: cancellation is checked before creating the directory.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testTemporaryExportCleanupRemovesOnlyDedicatedExportDirectory() throws {
        let sibling = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceScan-unrelated-\(UUID().uuidString).txt")
        let contents = Data("keep unrelated local files".utf8)
        try contents.write(to: sibling)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let exported = try ScanExporter.export(triangleFixture())
        let exportDirectory = exported.deletingLastPathComponent()
        let stale = exportDirectory.appendingPathComponent("interrupted-export.ply")
        try Data("interrupted".utf8).write(to: stale)

        ScanExporter.removeTemporaryExports()

        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportDirectory.path))
        XCTAssertEqual(try Data(contentsOf: sibling), contents)
        // Cleanup is safe on an already empty staging area, and export can
        // recreate its own directory for a later scan in the same app session.
        ScanExporter.removeTemporaryExports()
        let nextExport = try ScanExporter.export(triangleFixture())
        defer { try? FileManager.default.removeItem(at: nextExport) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: nextExport.path))
        XCTAssertEqual(try Data(contentsOf: sibling), contents)
    }

    func testLocalSaveWritesCompletePLYWithoutLeavingStagedFiles() throws {
        ScanExporter.removeTemporaryExports()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceScanSaved-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let savedURL = try ScanExporter.saveLocally(triangleFixture(), directory: directory)
        let file = try String(contentsOf: savedURL, encoding: .utf8)

        XCTAssertEqual(savedURL.deletingLastPathComponent().standardizedFileURL,
                       directory.standardizedFileURL)
        XCTAssertEqual(savedURL.pathExtension, "ply")
        XCTAssertTrue(file.hasPrefix("ply\nformat ascii 1.0\n"))
        XCTAssertTrue(file.contains("element vertex 3\n"))
        XCTAssertTrue(file.hasSuffix("3 0 1 2\n"))
        let stagedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceScanExports", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stagedDirectory.path), [])
    }

    func testStagingCleanupPreservesLocalSaveAndCancelledSaveCreatesNoFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceScanSaved-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mesh = triangleFixture()
        let savedURL = try ScanExporter.saveLocally(mesh, directory: directory)
        let savedContents = try Data(contentsOf: savedURL)

        ScanExporter.removeTemporaryExports()
        XCTAssertEqual(try Data(contentsOf: savedURL), savedContents)
        let cancelledSave = Task.detached { () throws -> URL in
            withUnsafeCurrentTask { $0?.cancel() }
            return try ScanExporter.saveLocally(mesh, directory: directory)
        }
        do {
            _ = try await cancelledSave.value
            XCTFail("A cancelled local save must not produce a file")
        } catch is CancellationError {
            // Expected before any additional local or staged output is created.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path),
                       [savedURL.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: savedURL), savedContents)
        let stagedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FaceScanExports", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDirectory.path))
    }

    private func triangleFixture() -> ScanMesh {
        ScanMesh(vertices: [
            ScanVertex(position: SIMD3(0.01, 0.02, 0.03), color: SIMD3(1, 0, 0.5)),
            ScanVertex(position: SIMD3(0.02, 0.02, 0.03), color: SIMD3(0, 1, 0)),
            ScanVertex(position: SIMD3(0.01, 0.03, 0.03), color: SIMD3(0, 0, 1))
        ], triangleIndices: [0, 1, 2], frameCount: 8, coveredAngles: [.center])
    }

    private func assertInvalid(_ mesh: ScanMesh, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ScanExporter.export(mesh), file: file, line: line) { error in
            guard case ScanExporter.ExportError.invalidGeometry = error else {
                return XCTFail("Expected invalidGeometry, received \(error)", file: file, line: line)
            }
        }
    }
}

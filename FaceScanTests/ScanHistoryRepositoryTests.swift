import Foundation
import XCTest
@testable import FaceScan

final class ScanHistoryRepositoryTests: XCTestCase {
    func testOriginalRoundTripPreservesFloatBitsTopologyAndCaptureMetadata() async throws {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = ScanHistoryRepository(directory: folder)
        let original = fixture()
        let date = Date(timeIntervalSince1970: 1_793_000_000.125)
        let entry = try await repository.save(original, id: original.renderIdentity, createdAt: date)
        let entries = try await repository.list()
        XCTAssertEqual(entries, [entry])
        XCTAssertEqual(entry.id, original.renderIdentity)
        XCTAssertEqual(entry.createdAt, date)
        XCTAssertEqual(entry.vertexCount, 3)
        XCTAssertEqual(entry.triangleCount, 1)
        XCTAssertEqual(entry.frameCount, original.frameCount)
        XCTAssertEqual(entry.coveredAngles, original.coveredAngles)
        XCTAssertEqual(entry.byteCount, 20 + 3 * 24 + 3 * 4)
        let loaded = try await repository.load(entry)
        assertExact(loaded, original)
        XCTAssertFalse(loaded.isFiltered)
        XCTAssertNil(loaded.filterSettings)
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testRelaunchAndDuplicateCompletionKeepTheFirstOriginalOnly() async throws {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = fixture()
        let first = ScanHistoryRepository(directory: folder)
        let entry = try await first.save(source, id: source.renderIdentity, createdAt: Date(timeIntervalSince1970: 10))
        let relaunched = ScanHistoryRepository(directory: folder)
        var changed = source
        changed.vertices[0].position.x = 0.5
        let repeated = try await relaunched.save(changed, id: source.renderIdentity, createdAt: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(repeated, entry)
        let entries = try await relaunched.list()
        XCTAssertEqual(entries, [entry])
        let recovered = try await relaunched.load(entry)
        assertExact(recovered, source)
        let children = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(children, [entry.id.uuidString], "No duplicate or abandoned staging directory should remain.")
    }

    func testListIsNewestFirstAndDeletionOnlyTouchesChosenHistory() async throws {
        let container = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let folder = container.appendingPathComponent("History", isDirectory: true)
        let unrelated = container.appendingPathComponent("Keep.txt")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try Data("preserved".utf8).write(to: unrelated)
        let repository = ScanHistoryRepository(directory: folder)
        let source = fixture()
        let oldest = try await repository.save(source, id: UUID(), createdAt: Date(timeIntervalSince1970: 10))
        let newest = try await repository.save(source, id: UUID(), createdAt: Date(timeIntervalSince1970: 30))
        let middle = try await repository.save(source, id: UUID(), createdAt: Date(timeIntervalSince1970: 20))
        let sorted = try await repository.list()
        XCTAssertEqual(sorted.map(\.id), [newest.id, middle.id, oldest.id])
        try await repository.delete(middle)
        try await repository.delete(middle)
        let remaining = try await repository.list()
        XCTAssertEqual(remaining.map(\.id), [newest.id, oldest.id])
        try await repository.deleteAll()
        let empty = try await repository.list()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "preserved")
        _ = try await repository.save(source, id: UUID(), createdAt: Date())
        let recreated = try await repository.list()
        XCTAssertEqual(recreated.count, 1, "New successful scans can be saved after clearing history.")
    }

    func testFilteredOrInvalidScansCannotCreateRecords() async throws {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = ScanHistoryRepository(directory: folder)
        var filtered = fixture()
        filtered.isFiltered = true
        await assertSaveFails(filtered, repository: repository, expected: .notOriginal)
        filtered.isFiltered = false
        filtered.filterSettings = .gentle
        await assertSaveFails(filtered, repository: repository, expected: .notOriginal)
        var invalid = fixture()
        invalid.vertices[1].position.z = .nan
        await assertSaveFails(invalid, repository: repository, expected: .invalidGeometry)
        invalid = fixture()
        invalid.vertices[1].color.z = 1.1
        await assertSaveFails(invalid, repository: repository, expected: .invalidGeometry)
        invalid = fixture()
        invalid.triangleIndices = [0, 1, 99]
        await assertSaveFails(invalid, repository: repository, expected: .invalidGeometry)
        invalid = fixture()
        invalid.triangleIndices = [0, 1]
        await assertSaveFails(invalid, repository: repository, expected: .invalidGeometry)
        invalid = fixture()
        invalid.vertices = []
        await assertSaveFails(invalid, repository: repository, expected: .invalidGeometry)
        let entries = try await repository.list()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testMalformedAndPartialEntriesDoNotHideOtherScans() async throws {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = ScanHistoryRepository(directory: folder)
        let valid = try await repository.save(fixture(), id: UUID())
        let damaged = try await repository.save(fixture(), id: UUID())
        let malformed = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
        try Data("invalid metadata".utf8).write(to: malformed.appendingPathComponent("metadata.json"))
        let partial = folder.appendingPathComponent(".staging-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("unfinished".utf8).write(to: partial.appendingPathComponent("points.bin"))
        try Data([0]).write(to: folder.appendingPathComponent(damaged.id.uuidString).appendingPathComponent("points.bin"))
        let entries = try await repository.list()
        XCTAssertEqual(entries, [valid])
        do {
            _ = try await repository.load(damaged)
            XCTFail("Truncated history must fail cleanly.")
        } catch { XCTAssertEqual(error as? ScanHistoryRepository.HistoryError, .damagedRecord) }
    }

    func testPayloadCorruptionIsDetectedBeforeReadingCoordinates() async throws {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = ScanHistoryRepository(directory: folder)
        let entry = try await repository.save(fixture(), id: UUID())
        let payload = folder.appendingPathComponent(entry.id.uuidString).appendingPathComponent("points.bin")
        var data = try Data(contentsOf: payload)
        data[24] ^= 0x80
        try data.write(to: payload)
        do {
            _ = try await repository.load(entry)
            XCTFail("A same-size damaged payload must be detected by its checksum.")
        } catch { XCTAssertEqual(error as? ScanHistoryRepository.HistoryError, .damagedRecord) }
        try await repository.delete(entry)
        do {
            _ = try await repository.load(entry)
            XCTFail("Deleted history must not open.")
        } catch { XCTAssertEqual(error as? ScanHistoryRepository.HistoryError, .missingRecord) }
    }

    func testPreCancelledSaveLeavesNoRecordAndFileSystemErrorsPropagate() async throws {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = ScanHistoryRepository(directory: folder)
        let source = fixture()
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.save(source, id: source.renderIdentity)
        }
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled history work must not commit.")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try Data("not a directory".utf8).write(to: folder)
        do {
            _ = try await repository.save(source, id: source.renderIdentity)
            XCTFail("Disk write failures must be reported to the history UI.")
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(try String(contentsOf: folder, encoding: .utf8), "not a directory")
    }

    func testSyntheticArchiveIsExplicitlyMarkedAndCoverageMetadataRejectsUnknownValues() async throws {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = ScanHistoryRepository(directory: folder)
        var sample = fixture()
        sample.isSample = true
        let entry = try await repository.save(sample, id: UUID())
        let restored = try await repository.load(entry)
        XCTAssertTrue(entry.isSample)
        XCTAssertTrue(restored.isSample)
        let url = folder.appendingPathComponent(entry.id.uuidString).appendingPathComponent("metadata.json")
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var storedEntry = try XCTUnwrap(metadata["entry"] as? [String: Any])
        storedEntry["coveredAngles"] = ["unknown"]
        metadata["entry"] = storedEntry
        try JSONSerialization.data(withJSONObject: metadata).write(to: url)
        let entries = try await repository.list()
        XCTAssertTrue(entries.isEmpty)
    }

    private func assertSaveFails(_ mesh: ScanMesh, repository: ScanHistoryRepository,
                                 expected: ScanHistoryRepository.HistoryError,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await repository.save(mesh, id: UUID())
            XCTFail("Expected invalid original scan to be rejected.", file: file, line: line)
        } catch { XCTAssertEqual(error as? ScanHistoryRepository.HistoryError, expected, file: file, line: line) }
    }

    private func assertExact(_ actual: ScanMesh, _ expected: ScanMesh,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.vertices.count, expected.vertices.count, file: file, line: line)
        for (left, right) in zip(actual.vertices, expected.vertices) {
            for component in 0..<3 {
                XCTAssertEqual(left.position[component].bitPattern, right.position[component].bitPattern, file: file, line: line)
                XCTAssertEqual(left.color[component].bitPattern, right.color[component].bitPattern, file: file, line: line)
            }
        }
        XCTAssertEqual(actual.triangleIndices, expected.triangleIndices, file: file, line: line)
        XCTAssertEqual(actual.frameCount, expected.frameCount, file: file, line: line)
        XCTAssertEqual(actual.coveredAngles, expected.coveredAngles, file: file, line: line)
        XCTAssertEqual(actual.isSample, expected.isSample, file: file, line: line)
    }

    private func fixture() -> ScanMesh {
        ScanMesh(vertices: [
            ScanVertex(position: SIMD3(-Float.zero, 0.02123457, -0.001234567), color: SIMD3(0.12345679, 0.8765432, -Float.zero)),
            ScanVertex(position: SIMD3(0.0197531, -0.03214567, 0.04123567), color: SIMD3(0.33333334, 0.6666667, 1)),
            ScanVertex(position: SIMD3(-0.00145971, 0.01459623, 0.003141592), color: SIMD3(0.24681358, 0.13579246, 0.56789124))
        ], triangleIndices: [0, 1, 2], frameCount: 19, coveredAngles: [.center, .left, .forehead])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FaceScanHistoryTests-\(UUID())", isDirectory: true)
    }
}

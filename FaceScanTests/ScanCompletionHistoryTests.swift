import XCTest
@testable import FaceScan

final class ScanCompletionHistoryTests: XCTestCase {
    @MainActor
    func testCompletedOriginalPersistsAfterScannerResetAndHistoryRelaunch() async throws {
        let defaultsName = "FaceScan-history-integration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("History-\(UUID().uuidString)")
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: folder)
        }
        let consent = PrivacyConsentStore(defaults: defaults)
        consent.accept()
        let history = ScanHistoryStore(repository: ScanHistoryRepository(directory: folder))
        let scanner = FaceScanController(privacyConsent: consent) { history.recordCompletedScan($0) }
        let original = source()
        scanner.phase = .processing
        scanner.finishProcessing(original)
        scanner.stop()
        await history.waitUntilIdle()
        XCTAssertNil(scanner.result)
        XCTAssertNil(history.errorMessage)

        let reopened = ScanHistoryRepository(directory: folder)
        let entries = try await reopened.list()
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.id, original.renderIdentity)
        let restored = try await reopened.load(entry)
        XCTAssertEqual(restored.vertices.map(\.position), original.vertices.map(\.position))
        XCTAssertEqual(restored.vertices.map(\.color), original.vertices.map(\.color))
        XCTAssertEqual(restored.triangleIndices, original.triangleIndices)
        XCTAssertEqual(restored.frameCount, original.frameCount)
        XCTAssertEqual(restored.coveredAngles, original.coveredAngles)
        XCTAssertFalse(restored.isFiltered)
    }

    @MainActor
    func testSuccessfulCompletionArchivesEachOriginalExactlyOnce() throws {
        try withConsent { consent in
            consent.accept()
            var completed: [ScanMesh] = []
            let scanner = FaceScanController(privacyConsent: consent) { completed.append($0) }
            let first = source()
            scanner.phase = .processing
            scanner.finishProcessing(first)
            scanner.finishProcessing(first)
            XCTAssertEqual(completed.count, 1)
            XCTAssertEqual(completed.first?.renderIdentity, first.renderIdentity)
            XCTAssertEqual(completed.first?.vertices.map(\.position), first.vertices.map(\.position))
            XCTAssertFalse(try XCTUnwrap(completed.first).isFiltered)
            XCTAssertEqual(scanner.phase, .complete)

            let next = source()
            scanner.phase = .processing
            scanner.finishProcessing(next)
            XCTAssertEqual(completed.map(\.renderIdentity), [first.renderIdentity, next.renderIdentity])
        }
    }

    @MainActor
    func testRejectedOrRevokedCompletionDoesNotArchive() throws {
        try withConsent { consent in
            var completed = 0
            let scanner = FaceScanController(privacyConsent: consent) { _ in completed += 1 }
            scanner.phase = .processing
            scanner.finishProcessing(source())
            XCTAssertEqual(completed, 0)
            consent.accept()
            scanner.phase = .ready
            scanner.finishProcessing(source())
            XCTAssertEqual(completed, 0)
            scanner.phase = .processing
            consent.revoke()
            scanner.finishProcessing(source())
            XCTAssertEqual(completed, 0)
            XCTAssertNil(scanner.result)
        }
    }

    @MainActor
    func testCompletionStillArchivesWhileHistoryOrFileViewingSuspendsCamera() throws {
        try withConsent { consent in
            consent.accept()
            var completed: [ScanMesh] = []
            let scanner = FaceScanController(privacyConsent: consent) { completed.append($0) }
            let original = source()
            scanner.phase = .processing
            scanner.suspendCaptureForFileViewing()
            scanner.finishProcessing(original)
            scanner.prepare()
            XCTAssertEqual(completed.count, 1)
            XCTAssertEqual(completed.first?.renderIdentity, original.renderIdentity)
            XCTAssertEqual(scanner.result?.renderIdentity, original.renderIdentity)
            XCTAssertEqual(scanner.phase, .complete)
            XCTAssertNil(scanner.session.currentFrame)
        }
    }

    private func source() -> ScanMesh {
        let vertices = (0..<100).map { index in
            ScanVertex(position: SIMD3(Float(index % 10) * 0.002, Float(index / 10) * 0.002, 0.04),
                       color: SIMD3(0.71353, 0.51233, 0.43217))
        }
        return ScanMesh(vertices: vertices, triangleIndices: [0, 1, 10],
                        frameCount: 8, coveredAngles: [.center, .left])
    }

    @MainActor
    private func withConsent(_ body: (PrivacyConsentStore) throws -> Void) throws {
        let name = "FaceScan-completion-history-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(PrivacyConsentStore(defaults: defaults))
    }
}

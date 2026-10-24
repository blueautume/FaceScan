import XCTest
@testable import FaceScan

final class ScanPrivacyGateTests: XCTestCase {
    @MainActor
    func testPreparationAndResetNeverStartCameraBeforeConsent() throws {
        let name = "FaceScanPrivacyGate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let consent = PrivacyConsentStore(defaults: defaults)
        let scanner = FaceScanController(privacyConsent: consent)
        scanner.prepare()
        scanner.startScan()
        scanner.reset()
        XCTAssertEqual(scanner.phase, .idle)
        XCTAssertNil(scanner.session.currentFrame)
        XCTAssertNil(scanner.result)
    }

    @MainActor
    func testRevocationClearsResultAndBlocksResume() throws {
        let name = "FaceScanPrivacyGate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let consent = PrivacyConsentStore(defaults: defaults)
        consent.accept()
        let scanner = FaceScanController(privacyConsent: consent)
        scanner.result = SampleFaceMesh.make()
        scanner.phase = .complete
        consent.revoke()
        scanner.stop()
        scanner.prepare()
        scanner.startScan()
        XCTAssertEqual(scanner.phase, .idle)
        XCTAssertNil(scanner.result)
        XCTAssertNil(scanner.livePointCloud)
        XCTAssertEqual(scanner.progress.acceptedFrames, 0)
    }

    @MainActor
    func testFileViewingBlocksCameraPreparationEvenWithConsent() throws {
        let name = "FaceScanFileGate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let consent = PrivacyConsentStore(defaults: defaults)
        consent.accept()
        let scanner = FaceScanController(privacyConsent: consent)
        scanner.suspendCaptureForFileViewing()
        scanner.prepare()
        scanner.startScan()
        XCTAssertEqual(scanner.phase, .idle)
        XCTAssertNil(scanner.session.currentFrame)
    }

    @MainActor
    func testOpeningAFilePreservesCompletedUnsavedScan() throws {
        let name = "FaceScanFileGate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let consent = PrivacyConsentStore(defaults: defaults)
        consent.accept()
        let scanner = FaceScanController(privacyConsent: consent)
        let mesh = SampleFaceMesh.make()
        scanner.result = mesh
        scanner.phase = .complete
        scanner.suspendCaptureForFileViewing()
        scanner.prepare()
        scanner.allowCaptureAfterFileViewing()
        XCTAssertEqual(scanner.phase, .complete)
        XCTAssertEqual(scanner.result?.vertexCount, mesh.vertexCount)
        XCTAssertEqual(scanner.result?.vertices.first?.position, mesh.vertices.first?.position)
    }

}

import XCTest
@testable import FaceScan

final class ScanEnhancementControllerTests: XCTestCase {
    @MainActor
    func testDisplayCopyPreservesSourceAndReusesRawFilteredCache() async throws {
        let raw = mesh()
        var filtered = mesh()
        filtered.isFiltered = true
        let worker = EnhancementWorkerGate()
        let controller = ScanEnhancementController { source, settings in
            try await worker.process(source, settings: settings)
        }
        let settings = ScanEnhancementSettings()
        controller.start(raw, settings: settings)
        await worker.waitForRequest(raw.renderIdentity)
        await worker.complete(raw, with: output(raw))
        await controller.waitUntilFinished()
        let display = try XCTUnwrap(controller.result(for: raw))
        XCTAssertEqual(display.mesh.vertexCount, raw.vertexCount + 1)
        XCTAssertTrue(display.mesh.triangleIndices.isEmpty)
        XCTAssertEqual(raw.vertexCount, 3)
        XCTAssertEqual(raw.triangleIndices, [0, 1, 2])
        XCTAssertEqual(controller.displayedMesh(for: raw, isEnabled: false).renderIdentity, raw.renderIdentity)
        XCTAssertEqual(controller.displayedMesh(for: raw, isEnabled: true).renderIdentity, display.mesh.renderIdentity)

        controller.start(filtered, settings: settings)
        await worker.waitForRequest(filtered.renderIdentity)
        XCTAssertNil(controller.result(for: raw))
        XCTAssertNil(controller.result(for: filtered))
        await worker.complete(filtered, with: output(filtered))
        await controller.waitUntilFinished()
        XCTAssertTrue(try XCTUnwrap(controller.result(for: filtered)).mesh.isFiltered)
        controller.start(raw, settings: settings)
        XCTAssertEqual(controller.result(for: raw)?.mesh.renderIdentity, display.mesh.renderIdentity)
        let count = await worker.requestCount
        XCTAssertEqual(count, 2, "Comparing raw and filtered results should reuse their display copies.")
    }

    @MainActor
    func testSupersededWorkerCannotPublishIntoNewSourceAndResetClearsCopies() async throws {
        let first = mesh(), next = mesh()
        let worker = EnhancementWorkerGate()
        let controller = ScanEnhancementController { source, settings in
            try await worker.process(source, settings: settings)
        }
        controller.start(first, settings: ScanEnhancementSettings())
        await worker.waitForRequest(first.renderIdentity)
        let waiting = expectation(description: "Old task captured")
        let old = Task { @MainActor in
            waiting.fulfill()
            await controller.waitUntilFinished()
        }
        await fulfillment(of: [waiting], timeout: 2)
        controller.start(next, settings: ScanEnhancementSettings())
        await worker.waitForRequest(next.renderIdentity)
        await worker.complete(first, with: output(first))
        await old.value
        XCTAssertTrue(controller.isProcessing)
        XCTAssertNil(controller.presentation)
        await worker.complete(next, with: output(next))
        await controller.waitUntilFinished()
        XCTAssertNotNil(controller.result(for: next))
        controller.reset()
        XCTAssertNil(controller.presentation)
        XCTAssertFalse(controller.isProcessing)
    }

    @MainActor
    func testFailedParameterChangeKeepsPriorDisplayAndRetryCanComplete() async throws {
        let source = mesh()
        let worker = EnhancementWorkerGate()
        let controller = ScanEnhancementController { source, settings in
            try await worker.process(source, settings: settings)
        }
        let settings = ScanEnhancementSettings()
        controller.start(source, settings: settings)
        await worker.waitForRequest(source.renderIdentity)
        await worker.complete(source, with: output(source))
        await controller.waitUntilFinished()
        let previous = try XCTUnwrap(controller.result(for: source))
        var changed = settings
        changed.targetSpacing = 0.001
        controller.start(source, settings: changed)
        await worker.waitForRequest(source.renderIdentity)
        XCTAssertEqual(controller.result(for: source)?.mesh.renderIdentity, previous.mesh.renderIdentity)
        await worker.fail(source)
        await controller.waitUntilFinished()
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.result(for: source)?.mesh.renderIdentity, previous.mesh.renderIdentity)
        controller.start(source, settings: changed)
        await worker.waitForRequest(source.renderIdentity)
        XCTAssertNil(controller.errorMessage)
        await worker.complete(source, with: output(source))
        await controller.waitUntilFinished()
        XCTAssertEqual(controller.result(for: source)?.settings, changed)
    }

    private func mesh() -> ScanMesh {
        ScanMesh(vertices: [
            ScanVertex(position: SIMD3(-0.001, 0, 0.02), color: SIMD3(0.6, 0.4, 0.3)),
            ScanVertex(position: SIMD3(0.001, 0, 0.02), color: SIMD3(0.6, 0.4, 0.3)),
            ScanVertex(position: SIMD3(0, 0.002, 0.02), color: SIMD3(0.6, 0.4, 0.3))
        ], triangleIndices: [0, 1, 2], frameCount: 8, coveredAngles: [.center])
    }

    private func output(_ source: ScanMesh) -> PointCloudEnhancementResult {
        let added = ScanVertex(position: SIMD3(0, 0.0005, 0.02), color: SIMD3(0.6, 0.4, 0.3))
        return PointCloudEnhancementResult(vertices: source.vertices + [added], originalPointCount: source.vertexCount,
                                          addedPointCount: 1, elapsedSeconds: 0.01, reachedLimit: false)
    }
}

private actor EnhancementWorkerGate {
    private var pending: [UUID: CheckedContinuation<PointCloudEnhancementResult, Error>] = [:]
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var requestCount = 0

    func process(_ source: ScanMesh, settings: ScanEnhancementSettings) async throws -> PointCloudEnhancementResult {
        try await withCheckedThrowingContinuation { continuation in
            requestCount += 1
            pending[source.renderIdentity] = continuation
            waiters.removeValue(forKey: source.renderIdentity)?.forEach { $0.resume() }
        }
    }
    func waitForRequest(_ identity: UUID) async {
        guard pending[identity] == nil else { return }
        await withCheckedContinuation { waiters[identity, default: []].append($0) }
    }
    func complete(_ source: ScanMesh, with result: PointCloudEnhancementResult) {
        pending.removeValue(forKey: source.renderIdentity)!.resume(returning: result)
    }
    func fail(_ source: ScanMesh) {
        pending.removeValue(forKey: source.renderIdentity)!.resume(throwing: Failure.failed)
    }
    private enum Failure: LocalizedError {
        case failed
        var errorDescription: String? { "Display enhancement test failure" }
    }
}

import Combine
import Foundation
import XCTest
@testable import FaceScan

final class ScanFilterControllerTests: XCTestCase {
    @MainActor
    func testSuccessShowsFilteredCopyAndCanSwitchBackWithoutReprocessing() async throws {
        let source = sourceMesh()
        let originalPositions = source.vertices.map(\.position)
        let output = filteredResult(from: source)
        let gate = FilterWorkerGate()
        let controller = ScanFilterController { mesh, settings in try await gate.process(mesh, settings: settings) }

        controller.start(source)
        XCTAssertTrue(controller.isFiltering)
        XCTAssertEqual(controller.progress, 0)
        XCTAssertEqual(controller.displayedMesh(for: source).renderIdentity, source.renderIdentity)
        await gate.waitForRequest(source.renderIdentity)
        controller.start(source)
        await gate.succeed(source.renderIdentity, with: output)
        await controller.waitUntilFinished()

        XCTAssertFalse(controller.isFiltering)
        XCTAssertEqual(controller.progress, 1)
        XCTAssertTrue(controller.showsFiltered)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.displayedMesh(for: source).renderIdentity, output.mesh.renderIdentity)
        XCTAssertEqual(source.vertices.map(\.position), originalPositions)
        XCTAssertEqual(source.triangleIndices, [0, 1, 2])
        XCTAssertFalse(source.isFiltered)

        controller.showsFiltered = false
        XCTAssertEqual(controller.displayedMesh(for: source).renderIdentity, source.renderIdentity)
        controller.start(source)
        XCTAssertTrue(controller.showsFiltered)
        XCTAssertEqual(controller.displayedMesh(for: source).renderIdentity, output.mesh.renderIdentity)
        let count = await gate.requestCount
        XCTAssertEqual(count, 1, "Repeated taps and showing the cached result must not filter twice.")
    }

    @MainActor
    func testResultNeverAppliesToAnotherScanOrChangedGeometry() async throws {
        let source = sourceMesh()
        let output = filteredResult(from: source)
        let controller = ScanFilterController { _, _ in output }
        controller.start(source)
        await controller.waitUntilFinished()

        let anotherScan = sourceMesh()
        XCTAssertNil(controller.result(for: anotherScan))
        XCTAssertEqual(controller.displayedMesh(for: anotherScan).renderIdentity, anotherScan.renderIdentity)
        var changedSource = source
        changedSource.vertices[0].position.z += 0.01
        XCTAssertNil(controller.result(for: changedSource))
        XCTAssertEqual(controller.displayedMesh(for: changedSource).renderIdentity, changedSource.renderIdentity)
    }

    @MainActor
    func testResetDiscardsLateNonCooperativeWorkerAndAllowsNewScan() async throws {
        let source = sourceMesh()
        let gate = FilterWorkerGate()
        let controller = ScanFilterController { mesh, settings in try await gate.process(mesh, settings: settings) }
        controller.start(source)
        await gate.waitForRequest(source.renderIdentity)
        let oldCompletion = await completionOfCurrentWork(controller)

        controller.reset()
        XCTAssertFalse(controller.isFiltering)
        XCTAssertNil(controller.result)
        let nextSource = sourceMesh()
        let nextOutput = filteredResult(from: nextSource)
        controller.start(nextSource)
        await gate.waitForRequest(nextSource.renderIdentity)

        // This worker deliberately ignores cancellation and returns after reset.
        await gate.succeed(source.renderIdentity, with: filteredResult(from: source))
        await oldCompletion.value
        XCTAssertTrue(controller.isFiltering, "An old completion must not clear a new scan's busy state.")
        XCTAssertNil(controller.result)
        XCTAssertEqual(controller.displayedMesh(for: nextSource).renderIdentity, nextSource.renderIdentity)

        await gate.succeed(nextSource.renderIdentity, with: nextOutput)
        await controller.waitUntilFinished()
        XCTAssertEqual(controller.result(for: nextSource)?.mesh.renderIdentity, nextOutput.mesh.renderIdentity)
        XCTAssertNil(controller.result(for: source))
    }

    @MainActor
    func testCancelDiscardsLateOutputAndKeepsCompletedComparison() async throws {
        let source = sourceMesh()
        let gate = FilterWorkerGate()
        let controller = ScanFilterController { mesh, settings in try await gate.process(mesh, settings: settings) }
        controller.start(source)
        await gate.waitForRequest(source.renderIdentity)
        let completion = await completionOfCurrentWork(controller)
        controller.cancel()
        XCTAssertFalse(controller.isFiltering)
        await gate.succeed(source.renderIdentity, with: filteredResult(from: source))
        await completion.value
        XCTAssertNil(controller.result)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.displayedMesh(for: source).renderIdentity, source.renderIdentity)

        controller.start(source)
        await gate.waitForRequest(source.renderIdentity)
        let output = filteredResult(from: source)
        await gate.succeed(source.renderIdentity, with: output)
        await controller.waitUntilFinished()
        controller.cancel()
        XCTAssertEqual(controller.result(for: source)?.mesh.renderIdentity, output.mesh.renderIdentity)
        XCTAssertEqual(controller.displayedMesh(for: source).renderIdentity, output.mesh.renderIdentity)
    }

    @MainActor
    func testFailurePreservesOriginalAndRetryCanSucceed() async throws {
        let source = sourceMesh()
        let gate = FilterWorkerGate()
        let controller = ScanFilterController { mesh, settings in try await gate.process(mesh, settings: settings) }
        controller.start(source)
        await gate.waitForRequest(source.renderIdentity)
        await gate.fail(source.renderIdentity)
        await controller.waitUntilFinished()

        XCTAssertFalse(controller.isFiltering)
        XCTAssertEqual(controller.progress, 0)
        XCTAssertEqual(controller.errorMessage, "Test processing failure")
        XCTAssertNil(controller.result)
        XCTAssertEqual(controller.displayedMesh(for: source).renderIdentity, source.renderIdentity)

        controller.start(source)
        XCTAssertEqual(controller.progress, 0)
        XCTAssertNil(controller.errorMessage)
        await gate.waitForRequest(source.renderIdentity)
        let output = filteredResult(from: source)
        await gate.succeed(source.renderIdentity, with: output)
        await controller.waitUntilFinished()
        XCTAssertEqual(controller.displayedMesh(for: source).renderIdentity, output.mesh.renderIdentity)
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor
    func testProgressIsBoundedMonotonicAndFinishesAtOne() async throws {
        let source = sourceMesh()
        let gate = ProgressFilterWorkerGate()
        let controller = ScanFilterController(progressProcessor: { mesh, settings, progress in
            try await gate.process(mesh, settings: settings, progress: progress)
        })
        let partial = expectation(description: "First completed work")
        let later = expectation(description: "Later completed work")
        let bounded = expectation(description: "Out-of-range progress is bounded")
        var completionPublications = 0
        let subscription = controller.$progress.sink { value in
            if value == 0.4 { partial.fulfill() }
            if value == 0.8 { later.fulfill() }
            if value == 1 {
                completionPublications += 1
                if completionPublications == 1 { bounded.fulfill() }
            }
        }
        defer { subscription.cancel() }

        controller.start(source)
        await gate.waitForRequest(source.renderIdentity)
        await gate.report(source.renderIdentity, value: 0.4)
        await fulfillment(of: [partial], timeout: 2)
        XCTAssertEqual(controller.progress, 0.4)
        await gate.report(source.renderIdentity, value: 0.1)
        await gate.report(source.renderIdentity, value: .nan)
        await gate.report(source.renderIdentity, value: 0.8)
        await fulfillment(of: [later], timeout: 2)
        XCTAssertEqual(controller.progress, 0.8)
        await gate.report(source.renderIdentity, value: 1.2)
        await fulfillment(of: [bounded], timeout: 2)
        XCTAssertEqual(controller.progress, 1)
        await gate.succeed(source.renderIdentity, with: filteredResult(from: source))
        await controller.waitUntilFinished()
        XCTAssertEqual(controller.progress, 1)
        XCTAssertEqual(completionPublications, 1,
                       "Worker completion and publishing its accepted result must not emit duplicate completion.")
        XCTAssertFalse(controller.isFiltering)
        controller.cancel()
        XCTAssertEqual(controller.progress, 0)
        controller.start(source)
        XCTAssertEqual(controller.progress, 1, "Showing a cached, complete result is immediately complete.")
        XCTAssertFalse(controller.isFiltering)
    }

    @MainActor
    func testCancelledWorkerCannotPublishProgressIntoTheNextScan() async throws {
        let source = sourceMesh()
        let nextSource = sourceMesh()
        let gate = ProgressFilterWorkerGate()
        let controller = ScanFilterController(progressProcessor: { mesh, settings, progress in
            try await gate.process(mesh, settings: settings, progress: progress)
        })
        controller.start(source)
        await gate.waitForRequest(source.renderIdentity)
        let oldCompletion = await completionOfCurrentWork(controller)
        controller.cancel()
        XCTAssertEqual(controller.progress, 0)
        controller.start(nextSource)
        await gate.waitForRequest(nextSource.renderIdentity)

        let nextProgress = expectation(description: "Only new scan progress")
        let subscription = controller.$progress.sink { value in
            if value == 0.25 { nextProgress.fulfill() }
        }
        defer { subscription.cancel() }
        await gate.report(source.renderIdentity, value: 0.95)
        await gate.report(nextSource.renderIdentity, value: 0.25)
        await fulfillment(of: [nextProgress], timeout: 2)
        await gate.succeed(source.renderIdentity, with: filteredResult(from: source))
        await oldCompletion.value
        XCTAssertEqual(controller.progress, 0.25)
        XCTAssertTrue(controller.isFiltering)
        XCTAssertNil(controller.result)

        await gate.succeed(nextSource.renderIdentity, with: filteredResult(from: nextSource))
        await controller.waitUntilFinished()
        XCTAssertEqual(controller.progress, 1)
        XCTAssertNotNil(controller.result(for: nextSource))
    }

    @MainActor
    func testFailedProgressResetsBeforeARetry() async throws {
        let source = sourceMesh()
        let gate = ProgressFilterWorkerGate()
        let controller = ScanFilterController(progressProcessor: { mesh, settings, progress in
            try await gate.process(mesh, settings: settings, progress: progress)
        })
        let partial = expectation(description: "Work before failure")
        let subscription = controller.$progress.sink { value in
            if value == 0.6 { partial.fulfill() }
        }
        defer { subscription.cancel() }
        controller.start(source)
        await gate.waitForRequest(source.renderIdentity)
        await gate.report(source.renderIdentity, value: 0.6)
        await fulfillment(of: [partial], timeout: 2)
        await gate.fail(source.renderIdentity)
        await controller.waitUntilFinished()
        XCTAssertEqual(controller.progress, 0)
        XCTAssertFalse(controller.isFiltering)
        XCTAssertNotNil(controller.errorMessage)

        controller.start(source)
        XCTAssertEqual(controller.progress, 0)
        XCTAssertNil(controller.errorMessage)
        await gate.waitForRequest(source.renderIdentity)
        await gate.succeed(source.renderIdentity, with: filteredResult(from: source))
        await controller.waitUntilFinished()
        XCTAssertEqual(controller.progress, 1)
    }

    @MainActor
    func testChangedSettingsReprocessOriginalAndUnchangedSettingsUseCache() async throws {
        let source = sourceMesh()
        let gate = FilterWorkerGate()
        let controller = ScanFilterController { mesh, settings in try await gate.process(mesh, settings: settings) }
        controller.start(source, settings: .reference)
        await gate.waitForRequest(source.renderIdentity)
        let firstOutput = filteredResult(from: source)
        await gate.succeed(source.renderIdentity, with: firstOutput)
        await controller.waitUntilFinished()

        controller.showsFiltered = false
        controller.start(source, settings: .gentle)
        await gate.waitForRequest(source.renderIdentity)
        XCTAssertFalse(controller.showsFiltered, "Changing parameters preserves the selected comparison during work.")
        XCTAssertEqual(controller.result(for: source)?.settings, .reference)
        let inputs = await gate.receivedMeshes
        let configurations = await gate.receivedSettings
        XCTAssertEqual(inputs.count, 2)
        XCTAssertTrue(inputs.allSatisfy { !$0.isFiltered && $0.renderIdentity == source.renderIdentity })
        XCTAssertEqual(inputs.last?.vertices.map(\.position), source.vertices.map(\.position),
                       "Re-filtering must never compound deformation by using the prior filtered result.")
        XCTAssertEqual(configurations, [.reference, .gentle])

        let secondOutput = filteredResult(from: source)
        await gate.succeed(source.renderIdentity, with: secondOutput)
        await controller.waitUntilFinished()
        XCTAssertTrue(controller.showsFiltered)
        XCTAssertEqual(controller.result(for: source)?.settings, .gentle)
        XCTAssertEqual(controller.result(for: source)?.mesh.renderIdentity, secondOutput.mesh.renderIdentity)
        controller.start(source, settings: .gentle)
        let count = await gate.requestCount
        XCTAssertEqual(count, 2)
    }

    @MainActor
    func testFailedOrCancelledParameterRerunKeepsLastSuccessfulResult() async throws {
        let source = sourceMesh()
        let gate = FilterWorkerGate()
        let controller = ScanFilterController { mesh, settings in try await gate.process(mesh, settings: settings) }
        controller.start(source)
        await gate.waitForRequest(source.renderIdentity)
        let previous = filteredResult(from: source)
        await gate.succeed(source.renderIdentity, with: previous)
        await controller.waitUntilFinished()

        controller.start(source, settings: .gentle)
        await gate.waitForRequest(source.renderIdentity)
        XCTAssertEqual(controller.displayedMesh(for: source).renderIdentity, previous.mesh.renderIdentity)
        await gate.fail(source.renderIdentity)
        await controller.waitUntilFinished()
        XCTAssertEqual(controller.result(for: source)?.settings, .reference)
        XCTAssertEqual(controller.displayedMesh(for: source).renderIdentity, previous.mesh.renderIdentity)
        XCTAssertNotNil(controller.errorMessage)

        controller.start(source, settings: .gentle)
        await gate.waitForRequest(source.renderIdentity)
        let cancelledCompletion = await completionOfCurrentWork(controller)
        controller.cancel()
        await gate.succeed(source.renderIdentity, with: filteredResult(from: source))
        await cancelledCompletion.value
        XCTAssertFalse(controller.isFiltering)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.result(for: source)?.settings, .reference)
        XCTAssertEqual(controller.displayedMesh(for: source).renderIdentity, previous.mesh.renderIdentity)

        controller.start(source, settings: .gentle)
        await gate.waitForRequest(source.renderIdentity)
        let replacement = filteredResult(from: source)
        await gate.succeed(source.renderIdentity, with: replacement)
        await controller.waitUntilFinished()
        XCTAssertEqual(controller.result(for: source)?.settings, .gentle)
        XCTAssertEqual(controller.displayedMesh(for: source).renderIdentity, replacement.mesh.renderIdentity)
    }

    @MainActor
    func testEditingOnlyTheCurveReprocessesTheOriginalWithACapturedConfiguration() async throws {
        let source = sourceMesh()
        let gate = FilterWorkerGate()
        let controller = ScanFilterController { mesh, settings in try await gate.process(mesh, settings: settings) }
        var settings = ScanFilterSettings.gentle
        settings.smoothingCurve = .featurePreserving
        controller.start(source, settings: settings)
        await gate.waitForRequest(source.renderIdentity)
        await gate.succeed(source.renderIdentity, with: filteredResult(from: source))
        await controller.waitUntilFinished()

        settings.smoothingCurve?.strengths[2] = 0.1
        let requested = settings
        controller.start(source, settings: settings)
        settings.smoothingCurve?.strengths[2] = 0.9
        await gate.waitForRequest(source.renderIdentity)
        let configurations = await gate.receivedSettings
        let meshes = await gate.receivedMeshes
        XCTAssertEqual(configurations.count, 2)
        XCTAssertEqual(configurations.last, requested)
        XCTAssertTrue(meshes.allSatisfy { !$0.isFiltered && $0.renderIdentity == source.renderIdentity })
        await gate.succeed(source.renderIdentity, with: filteredResult(from: source))
        await controller.waitUntilFinished()
        XCTAssertEqual(controller.result(for: source)?.settings, requested)
        controller.start(source, settings: requested)
        let count = await gate.requestCount
        XCTAssertEqual(count, 2, "An unchanged curve should reuse the completed result.")
    }

    @MainActor
    private func completionOfCurrentWork(_ controller: ScanFilterController) async -> Task<Void, Never> {
        let entered = expectation(description: "Completion waiter captured the current task")
        let completion = Task { @MainActor in
            entered.fulfill()
            // No actor hop occurs here: the current task is captured before this
            // main-actor closure yields, allowing reset/cancel to run afterwards.
            await controller.waitUntilFinished()
        }
        await fulfillment(of: [entered], timeout: 2)
        return completion
    }

    private func sourceMesh() -> ScanMesh {
        ScanMesh(vertices: [
            ScanVertex(position: SIMD3(-0.02, 0.01, 0.04), color: SIMD3(0.4, 0.5, 0.6)),
            ScanVertex(position: SIMD3(0.02, 0.01, 0.04), color: SIMD3(0.5, 0.6, 0.7)),
            ScanVertex(position: SIMD3(0, -0.02, 0.05), color: SIMD3(0.6, 0.7, 0.8))
        ], triangleIndices: [0, 1, 2], frameCount: 8, coveredAngles: [.center, .left])
    }

    private func filteredResult(from source: ScanMesh) -> ScanFilterResult {
        var vertices = source.vertices
        vertices[0].position.z += 0.001
        let mesh = ScanMesh(vertices: vertices, triangleIndices: [], frameCount: source.frameCount,
                            coveredAngles: source.coveredAngles, isSample: source.isSample,
                            isFiltered: true)
        let statistics = FaceCloudStatistics(inputCount: source.vertexCount, outputCount: mesh.vertexCount,
            sorRejectedCount: 0, modelRejectedCount: 0, sorDistanceThresholdMM: 2,
            medianDisplacementMM: 0.1, p95DisplacementMM: 1, maximumDisplacementMM: 1,
            observedGridCells: 3, elapsedSeconds: 0.01)
        return ScanFilterResult(mesh: mesh, statistics: statistics)
    }
}

private actor ProgressFilterWorkerGate {
    private var pending: [UUID: CheckedContinuation<ScanFilterResult, Error>] = [:]
    private var progressHandlers: [UUID: ScanFilterController.ProgressHandler] = [:]
    private var requestWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func process(_ mesh: ScanMesh, settings: ScanFilterSettings,
                 progress: @escaping ScanFilterController.ProgressHandler) async throws -> ScanFilterResult {
        try await withCheckedThrowingContinuation { continuation in
            progressHandlers[mesh.renderIdentity] = progress
            pending[mesh.renderIdentity] = continuation
            requestWaiters.removeValue(forKey: mesh.renderIdentity)?.forEach { $0.resume() }
        }
    }

    func waitForRequest(_ identity: UUID) async {
        guard pending[identity] == nil else { return }
        await withCheckedContinuation { requestWaiters[identity, default: []].append($0) }
    }

    func report(_ identity: UUID, value: Double) { progressHandlers[identity]?(value) }

    func succeed(_ identity: UUID, with result: ScanFilterResult) {
        pending.removeValue(forKey: identity)!.resume(returning: result)
    }

    func fail(_ identity: UUID) {
        pending.removeValue(forKey: identity)!.resume(throwing: NSError(domain: "ProgressFilterTests", code: 1))
    }
}

/// The gate intentionally does not observe task cancellation, so tests prove
/// controller generation checks independently of a cooperative CPU worker.
private actor FilterWorkerGate {
    private var pending: [UUID: CheckedContinuation<ScanFilterResult, Error>] = [:]
    private var requestWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var requestCount = 0
    private(set) var receivedMeshes: [ScanMesh] = []
    private(set) var receivedSettings: [ScanFilterSettings] = []

    func process(_ mesh: ScanMesh, settings: ScanFilterSettings) async throws -> ScanFilterResult {
        try await withCheckedThrowingContinuation { continuation in
            requestCount += 1
            receivedMeshes.append(mesh)
            receivedSettings.append(settings)
            pending[mesh.renderIdentity] = continuation
            requestWaiters.removeValue(forKey: mesh.renderIdentity)?.forEach { $0.resume() }
        }
    }

    func waitForRequest(_ identity: UUID) async {
        guard pending[identity] == nil else { return }
        await withCheckedContinuation { requestWaiters[identity, default: []].append($0) }
    }

    func succeed(_ identity: UUID, with result: ScanFilterResult) {
        pending.removeValue(forKey: identity)!.resume(returning: result)
    }

    func fail(_ identity: UUID) {
        pending.removeValue(forKey: identity)!.resume(throwing: WorkerFailure.requested)
    }

    private enum WorkerFailure: LocalizedError {
        case requested
        var errorDescription: String? { "Test processing failure" }
    }
}

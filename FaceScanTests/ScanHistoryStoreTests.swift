import XCTest
@testable import FaceScan

final class ScanHistoryStoreTests: XCTestCase {
    @MainActor
    func testOnlyOriginalCompletedScansAreRecordedOnceAndSourcesRemainIndependent() async throws {
        let disk = HistoryTestDisk()
        let history = makeStore(disk)
        let first = fixture(), second = fixture()
        var sample = fixture()
        sample.isSample = true
        var filtered = fixture()
        filtered.isFiltered = true
        var tagged = fixture()
        tagged.filterSettings = .reference
        let empty = ScanMesh(vertices: [], triangleIndices: [], frameCount: 0, coveredAngles: [])

        for mesh in [sample, filtered, tagged, empty] { history.recordCompletedScan(mesh) }
        history.recordCompletedScan(first)
        history.recordCompletedScan(first)
        history.recordCompletedScan(second)
        XCTAssertTrue(history.isSaving)
        await history.waitUntilIdle()

        XCTAssertEqual(Set(history.entries.map(\.id)), [first.renderIdentity, second.renderIdentity])
        XCTAssertFalse(history.isSaving)
        XCTAssertFalse(history.hasFailedSaves)
        let saves = await disk.savedIDs
        XCTAssertEqual(saves, [first.renderIdentity, second.renderIdentity])
        let storedSource = await disk.storedMesh(first.renderIdentity)
        let stored = try XCTUnwrap(storedSource)
        XCTAssertEqual(stored.vertices.map(\.position), first.vertices.map(\.position))
        XCTAssertEqual(stored.vertices.map(\.color), first.vertices.map(\.color))
        XCTAssertEqual(stored.triangleIndices, first.triangleIndices)
        XCTAssertFalse(stored.isFiltered)
    }

    @MainActor
    func testAnInFlightSaveKeepsItsSourceWhileAnotherScanQueues() async throws {
        let disk = HistoryTestDisk()
        let history = makeStore(disk)
        var first = fixture()
        let id = first.renderIdentity
        let positions = first.vertices.map(\.position)
        await disk.holdSave(id)
        history.recordCompletedScan(first)
        await disk.waitForSave(id)
        first.vertices.removeAll()
        history.recordCompletedScan(fixture())
        let started = await disk.savedIDs
        XCTAssertEqual(started, [id], "Subsequent scans must queue without cancelling the source being saved.")
        await disk.releaseSave(id)
        await history.waitUntilIdle()

        XCTAssertEqual(history.entries.count, 2)
        let storedSource = await disk.storedMesh(id)
        let stored = try XCTUnwrap(storedSource)
        XCTAssertEqual(stored.vertices.map(\.position), positions)
    }

    @MainActor
    func testFailedSaveRetainsOriginalForExplicitRetryWithoutDuplicatingCompletion() async throws {
        let disk = HistoryTestDisk()
        let history = makeStore(disk)
        let source = fixture()
        await disk.setSaveFailure(true)
        history.recordCompletedScan(source)
        await history.waitUntilIdle()
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertFalse(history.isSaving)
        XCTAssertTrue(history.hasFailedSaves)
        XCTAssertNotNil(history.errorMessage)
        history.recordCompletedScan(source)
        await history.waitUntilIdle()
        let initialCount = await disk.savedIDs.count
        XCTAssertEqual(initialCount, 1)

        await disk.setSaveFailure(false)
        history.retryFailedSaves()
        XCTAssertTrue(history.isSaving)
        await history.waitUntilIdle()
        XCTAssertEqual(history.entries.map(\.id), [source.renderIdentity])
        XCTAssertFalse(history.hasFailedSaves)
        XCTAssertNil(history.errorMessage)
        let dates = await disk.dates(for: source.renderIdentity)
        XCTAssertEqual(dates.count, 2)
        XCTAssertEqual(dates.first, dates.last, "A retry retains the scan's original completion timestamp.")
    }

    @MainActor
    func testClearWaitsForNonCooperativeInFlightWriteAndDropsQueuedSources() async throws {
        let disk = HistoryTestDisk()
        let history = makeStore(disk)
        let first = fixture(), queued = fixture()
        await disk.holdSave(first.renderIdentity)
        history.recordCompletedScan(first)
        await disk.waitForSave(first.renderIdentity)
        history.recordCompletedScan(queued)
        history.clearAll()
        XCTAssertTrue(history.isClearing)
        history.recordCompletedScan(first)
        await disk.releaseSave(first.renderIdentity)
        await history.waitUntilIdle()

        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertFalse(history.isSaving)
        XCTAssertFalse(history.isClearing)
        XCTAssertFalse(history.hasFailedSaves)
        let remaining = await disk.list()
        let saved = await disk.savedIDs
        let events = await disk.events
        XCTAssertTrue(remaining.isEmpty, "A late disk write must be removed before clearing finishes.")
        XCTAssertEqual(saved, [first.renderIdentity], "The queued old scan must never begin writing.")
        XCTAssertEqual(events, [.saved(first.renderIdentity), .cleared])
    }

    @MainActor
    func testNewCompletionAfterClearRequestIsSavedAfterTheClear() async throws {
        let disk = HistoryTestDisk()
        let history = makeStore(disk)
        let before = fixture(), after = fixture()
        await disk.holdSave(before.renderIdentity)
        history.recordCompletedScan(before)
        await disk.waitForSave(before.renderIdentity)
        history.clearAll()
        history.recordCompletedScan(after)
        await disk.releaseSave(before.renderIdentity)
        await history.waitUntilIdle()

        XCTAssertEqual(history.entries.map(\.id), [after.renderIdentity])
        let remaining = await disk.list()
        let events = await disk.events
        XCTAssertEqual(remaining.map(\.id), [after.renderIdentity])
        XCTAssertEqual(events, [.saved(before.renderIdentity), .cleared, .saved(after.renderIdentity)])
    }

    @MainActor
    func testClearDiscardsFailedRetryAndDeletionDoesNotRestoreRemovedRecord() async throws {
        let disk = HistoryTestDisk()
        let history = makeStore(disk)
        let failed = fixture()
        await disk.setSaveFailure(true)
        history.recordCompletedScan(failed)
        await history.waitUntilIdle()
        history.clearAll()
        await history.waitUntilIdle()
        await disk.setSaveFailure(false)
        history.retryFailedSaves()
        history.recordCompletedScan(failed)
        await history.waitUntilIdle()
        let failedCalls = await disk.savedIDs
        XCTAssertEqual(failedCalls, [failed.renderIdentity])
        XCTAssertFalse(history.hasFailedSaves)

        let fresh = fixture()
        history.recordCompletedScan(fresh)
        await history.waitUntilIdle()
        let entry = try XCTUnwrap(history.entries.first)
        let loaded = try await history.load(entry)
        XCTAssertEqual(loaded.vertices.map(\.position), fresh.vertices.map(\.position))
        history.delete(entry)
        await history.waitUntilIdle()
        history.recordCompletedScan(fresh)
        await history.waitUntilIdle()
        XCTAssertTrue(history.entries.isEmpty)
        let remaining = await disk.list()
        XCTAssertTrue(remaining.isEmpty)
    }

    @MainActor
    func testRefreshRestoresPersistedEntriesAndFailedClearRemainsVisibleForRetry() async throws {
        let disk = HistoryTestDisk()
        let source = fixture()
        let entry = try await disk.save(source, id: source.renderIdentity, date: Date(timeIntervalSince1970: 1_000))
        let history = makeStore(disk)
        history.refresh()
        await history.waitUntilIdle()
        XCTAssertEqual(history.entries, [entry])
        XCTAssertFalse(history.isLoading)
        history.recordCompletedScan(source)
        await history.waitUntilIdle()
        let calls = await disk.savedIDs
        XCTAssertEqual(calls.count, 1, "Refreshing known IDs must prevent duplicate completion writes.")

        await disk.setClearFailure(true)
        history.clearAll()
        await history.waitUntilIdle()
        XCTAssertEqual(history.entries, [entry])
        XCTAssertFalse(history.isClearing)
        XCTAssertNotNil(history.errorMessage)
        await disk.setClearFailure(false)
        history.clearAll()
        await history.waitUntilIdle()
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertNil(history.errorMessage)
    }

    #if DEBUG
    @MainActor
    func testExplicitPreviewFixtureIsMarkedSyntheticAndUsesStableIdentity() async throws {
        let disk = HistoryTestDisk()
        let history = makeStore(disk)
        var sample = fixture()
        sample.isSample = true
        let previewID = UUID()
        history.recordPreviewSample(sample, id: previewID)
        history.recordPreviewSample(sample, id: previewID)
        await history.waitUntilIdle()
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.id, previewID)
        XCTAssertEqual(history.entries.first?.isSample, true)
        let saved = await disk.savedIDs
        XCTAssertEqual(saved, [previewID])
    }
    #endif

    @MainActor
    private func makeStore(_ disk: HistoryTestDisk) -> ScanHistoryStore {
        ScanHistoryStore(operations: .init(
            list: { await disk.list() },
            save: { try await disk.save($0, id: $1, date: $2) },
            load: { try await disk.load($0) },
            delete: { await disk.delete($0) },
            deleteAll: { try await disk.clear() }))
    }

    private func fixture() -> ScanMesh {
        ScanMesh(vertices: [
            ScanVertex(position: SIMD3(-0.0012345, 0, 0.02), color: SIMD3(0.612345, 0.456789, 0.312345)),
            ScanVertex(position: SIMD3(0.001, 0, 0.02), color: SIMD3(0.6, 0.4, 0.3)),
            ScanVertex(position: SIMD3(0, 0.002, 0.02), color: SIMD3(0.6, 0.4, 0.3))
        ], triangleIndices: [0, 1, 2], frameCount: 8, coveredAngles: [.center, .left])
    }
}

private actor HistoryTestDisk {
    enum Event: Equatable {
        case saved(UUID)
        case deleted(UUID)
        case cleared
    }
    private(set) var savedIDs: [UUID] = []
    private(set) var events: [Event] = []
    private var entries: [UUID: ScanHistoryEntry] = [:]
    private var meshes: [UUID: ScanMesh] = [:]
    private var saveDates: [UUID: [Date]] = [:]
    private var heldSaves: Set<UUID> = []
    private var saveContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var requestWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var failsSave = false
    private var failsClear = false

    func holdSave(_ id: UUID) { heldSaves.insert(id) }
    func setSaveFailure(_ value: Bool) { failsSave = value }
    func setClearFailure(_ value: Bool) { failsClear = value }
    func dates(for id: UUID) -> [Date] { saveDates[id] ?? [] }
    func storedMesh(_ id: UUID) -> ScanMesh? { meshes[id] }

    func waitForSave(_ id: UUID) async {
        guard !savedIDs.contains(id) else { return }
        await withCheckedContinuation { requestWaiters[id, default: []].append($0) }
    }

    func releaseSave(_ id: UUID) {
        heldSaves.remove(id)
        saveContinuations.removeValue(forKey: id)?.resume()
    }

    func save(_ mesh: ScanMesh, id: UUID, date: Date) async throws -> ScanHistoryEntry {
        savedIDs.append(id)
        saveDates[id, default: []].append(date)
        requestWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
        if heldSaves.contains(id) {
            await withCheckedContinuation { saveContinuations[id] = $0 }
        }
        if failsSave { throw Failure.failed }
        if let existing = entries[id] { return existing }
        let entry = ScanHistoryEntry(id: id, createdAt: date, vertexCount: mesh.vertexCount,
                                     triangleCount: mesh.triangleIndices.count / 3, frameCount: mesh.frameCount,
                                     coveredAngles: mesh.coveredAngles, byteCount: mesh.vertexCount * 24,
                                     isSample: mesh.isSample)
        entries[id] = entry
        meshes[id] = mesh
        events.append(.saved(id))
        return entry
    }

    func list() -> [ScanHistoryEntry] { Array(entries.values) }
    func load(_ entry: ScanHistoryEntry) throws -> ScanMesh {
        guard let mesh = meshes[entry.id] else { throw Failure.failed }
        return mesh
    }
    func delete(_ entry: ScanHistoryEntry) {
        entries.removeValue(forKey: entry.id)
        meshes.removeValue(forKey: entry.id)
        events.append(.deleted(entry.id))
    }
    func clear() throws {
        if failsClear { throw Failure.failed }
        entries.removeAll()
        meshes.removeAll()
        events.append(.cleared)
    }

    private enum Failure: LocalizedError {
        case failed
        var errorDescription: String? { "历史存储测试错误" }
    }
}

import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Saves the completed source independently of whichever result the UI opens
/// next. All disk mutations share one operation chain, including clear/delete.
@MainActor
final class ScanHistoryStore: ObservableObject {
    struct Operations: Sendable {
        var list: @Sendable () async throws -> [ScanHistoryEntry]
        var save: @Sendable (ScanMesh, UUID, Date) async throws -> ScanHistoryEntry
        var load: @Sendable (ScanHistoryEntry) async throws -> ScanMesh
        var delete: @Sendable (ScanHistoryEntry) async throws -> Void
        var deleteAll: @Sendable () async throws -> Void
    }

    @Published private(set) var entries: [ScanHistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isClearing = false
    @Published private(set) var hasFailedSaves = false
    @Published var errorMessage: String?

    private struct PendingSave {
        let mesh: ScanMesh
        let date: Date
        let generation: UUID
        var isQueued: Bool
    }

    private let operations: Operations
    private var generation = UUID()
    private var refreshGeneration = UUID()
    private var operationGeneration = UUID()
    private var operationTail: Task<Void, Never>?
    // Keep IDs after deletion/clear so an old completion callback cannot bring
    // a deliberately removed scan back during this app session.
    private var recordedIDs: Set<UUID> = []
    private var pending: [UUID: PendingSave] = [:]

    convenience init(repository: ScanHistoryRepository = ScanHistoryRepository()) {
        self.init(operations: Operations(
            list: { try await repository.list() },
            save: { try await repository.save($0, id: $1, createdAt: $2) },
            load: { try await repository.load($0) },
            delete: { try await repository.delete($0) },
            deleteAll: { try await repository.deleteAll() }))
    }

    init(operations: Operations) {
        self.operations = operations
    }

    func refresh() {
        let epoch = generation
        let request = UUID()
        refreshGeneration = request
        isLoading = true
        enqueue { store in
            guard store.generation == epoch, store.refreshGeneration == request else { return }
            do {
                let entries = try await store.operations.list()
                guard store.generation == epoch, store.refreshGeneration == request else { return }
                store.entries = Self.sorted(entries)
                store.recordedIDs.formUnion(entries.map(\.id))
                if !store.hasFailedSaves { store.errorMessage = nil }
            } catch {
                guard store.generation == epoch, store.refreshGeneration == request else { return }
                store.errorMessage = "无法读取历史记录：\(error.localizedDescription)"
            }
            store.isLoading = false
        }
    }

    /// Call only from the scanner's successful completion path. Filtered,
    /// enhanced, imported and synthetic previews never enter automatic history.
    func recordCompletedScan(_ mesh: ScanMesh) {
        guard !mesh.isSample, !mesh.isFiltered, mesh.filterSettings == nil,
              !mesh.vertices.isEmpty else { return }
        record(mesh, id: mesh.renderIdentity)
    }

    #if DEBUG
    /// An explicit developer launch fixture. A fixed ID avoids creating a new
    /// synthetic record every time the preview is opened or the app restarts.
    func recordPreviewSample(_ mesh: ScanMesh, id: UUID) {
        guard mesh.isSample, !mesh.isFiltered, mesh.filterSettings == nil,
              !mesh.vertices.isEmpty else { return }
        record(mesh, id: id)
    }
    #endif

    func retryFailedSaves() {
        let failed = pending.filter { !$0.value.isQueued }
            .sorted { $0.value.date < $1.value.date }
        guard !failed.isEmpty else { return }
        errorMessage = nil
        for (id, _) in failed {
            pending[id]?.isQueued = true
            enqueueSave(id)
        }
        updateSaveState()
    }

    func load(_ entry: ScanHistoryEntry) async throws -> ScanMesh {
        let epoch = generation
        // A newly completed scan may still be committing. Wait before reading
        // the list's entry; the repository itself serializes the actual I/O.
        await operationTail?.value
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        let mesh = try await operations.load(entry)
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        return mesh
    }

    func delete(_ entry: ScanHistoryEntry) {
        let epoch = generation
        enqueue { store in
            guard store.generation == epoch else { return }
            let background = ScanHistoryBackgroundActivity(name: "删除扫描历史")
            defer { background.end() }
            do {
                try await store.operations.delete(entry)
                guard store.generation == epoch else { return }
                store.entries.removeAll { $0.id == entry.id }
                if !store.hasFailedSaves { store.errorMessage = nil }
            } catch {
                guard store.generation == epoch else { return }
                store.errorMessage = "无法删除这份历史记录：\(error.localizedDescription)"
            }
        }
    }

    /// Invalidate queued work immediately, then wait for any disk write that
    /// already began before removing files. A late save can never revive them.
    func clearAll() {
        generation = UUID()
        refreshGeneration = UUID()
        let epoch = generation
        pending.removeAll()
        entries.removeAll()
        isLoading = false
        isClearing = true
        errorMessage = nil
        updateSaveState()
        enqueue { store in
            guard store.generation == epoch else { return }
            let background = ScanHistoryBackgroundActivity(name: "清除扫描历史")
            defer { background.end() }
            do {
                try await store.operations.deleteAll()
                guard store.generation == epoch else { return }
            } catch {
                guard store.generation == epoch else { return }
                store.errorMessage = "无法清除全部历史记录：\(error.localizedDescription)"
                // Reflect any files that survived a partial filesystem failure.
                if let remaining = try? await store.operations.list(), store.generation == epoch {
                    store.entries = Self.sorted(remaining)
                }
            }
            if store.generation == epoch { store.isClearing = false }
        }
    }

    func waitUntilIdle() async {
        while let task = operationTail {
            let request = operationGeneration
            await task.value
            if operationGeneration == request { return }
        }
    }

    private func record(_ mesh: ScanMesh, id: UUID) {
        guard recordedIDs.insert(id).inserted else { return }
        pending[id] = PendingSave(mesh: mesh, date: Date(), generation: generation, isQueued: true)
        if !hasFailedSaves { errorMessage = nil }
        updateSaveState()
        enqueueSave(id)
    }

    private func enqueueSave(_ id: UUID) {
        guard let pendingSave = pending[id] else { return }
        let epoch = pendingSave.generation
        enqueue { store in
            guard store.generation == epoch, let request = store.pending[id], request.isQueued else { return }
            let background = ScanHistoryBackgroundActivity(name: "保存原始扫描历史")
            defer { background.end() }
            do {
                let entry = try await store.operations.save(request.mesh, id, request.date)
                guard store.generation == epoch else { return }
                store.pending.removeValue(forKey: id)
                store.entries.removeAll { $0.id == entry.id }
                store.entries.append(entry)
                store.entries = Self.sorted(store.entries)
                store.updateSaveState()
                if !store.hasFailedSaves { store.errorMessage = nil }
            } catch {
                guard store.generation == epoch else { return }
                store.pending[id]?.isQueued = false
                store.updateSaveState()
                store.errorMessage = "原始扫描未能保存到历史：\(error.localizedDescription)。请重试保存。"
            }
        }
    }

    private func updateSaveState() {
        isSaving = pending.values.contains { $0.isQueued }
        hasFailedSaves = pending.values.contains { !$0.isQueued }
    }

    private func enqueue(_ operation: @escaping @MainActor (ScanHistoryStore) async -> Void) {
        let previous = operationTail
        operationGeneration = UUID()
        // Keep the store and its raw source alive until the operation commits,
        // even when the user has already restarted or changed the visible view.
        operationTail = Task { @MainActor [self] in
            await previous?.value
            await operation(self)
        }
    }

    private static func sorted(_ entries: [ScanHistoryEntry]) -> [ScanHistoryEntry] {
        entries.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt }
    }
}

/// Small local commits get a short background grace period. Expiration ends the
/// assertion safely; the atomic repository still owns partial-file cleanup.
@MainActor
private final class ScanHistoryBackgroundActivity {
    #if canImport(UIKit)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(name: String) {
        #if canImport(UIKit)
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor [weak self] in self?.end() }
        }
        #endif
    }

    func end() {
        #if canImport(UIKit)
        guard identifier != .invalid else { return }
        let active = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(active)
        #endif
    }
}

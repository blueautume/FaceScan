import Combine
import Foundation

/// Keeps a filtered copy beside the immutable completed scan. A cancelled or
/// superseded worker can never publish its result into a later scan.
@MainActor
final class ScanFilterController: ObservableObject {
    typealias Processor = @Sendable (ScanMesh, ScanFilterSettings) async throws -> ScanFilterResult
    typealias ProgressHandler = @Sendable (Double) -> Void
    typealias ProgressProcessor = @Sendable (ScanMesh, ScanFilterSettings, @escaping ProgressHandler) async throws -> ScanFilterResult

    @Published private(set) var result: ScanFilterResult?
    @Published private(set) var isFiltering = false
    @Published private(set) var progress = 0.0
    @Published var showsFiltered = true
    @Published var errorMessage: String?

    private var sourceIdentity: UUID?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private let processor: ProgressProcessor

    init(progressProcessor: @escaping ProgressProcessor = {
        try await ScanPointCloudFilter.processAsync($0, settings: $1, onProgress: $2)
    }) {
        self.processor = progressProcessor
    }

    /// Retains the simple injection used by existing callers and tests.
    convenience init(processor: @escaping Processor) {
        self.init(progressProcessor: { mesh, settings, _ in try await processor(mesh, settings) })
    }

    deinit { task?.cancel() }

    func result(for source: ScanMesh) -> ScanFilterResult? {
        sourceIdentity == source.renderIdentity ? result : nil
    }

    func displayedMesh(for source: ScanMesh) -> ScanMesh {
        showsFiltered ? result(for: source)?.mesh ?? source : source
    }

    func start(_ source: ScanMesh, settings: ScanFilterSettings = .reference) {
        guard !isFiltering, !source.isFiltered else { return }
        if result(for: source)?.settings == settings {
            errorMessage = nil
            showsFiltered = true
            if progress != 1 { progress = 1 }
            return
        }
        if sourceIdentity != source.renderIdentity { reset() }
        else { cancel() }
        errorMessage = nil
        sourceIdentity = source.renderIdentity
        isFiltering = true
        if progress != 0 { progress = 0 }
        let token = generation
        let process = processor
        task = Task { [weak self] in
            do {
                let output = try await process(source, settings) { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.isFiltering, value.isFinite else { return }
                        let bounded = min(1, max(0, value))
                        guard bounded > self.progress else { return }
                        self.progress = bounded
                    }
                }
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.result = ScanFilterResult(mesh: output.mesh, statistics: output.statistics, settings: settings)
                self.showsFiltered = true
                if self.progress != 1 { self.progress = 1 }
                self.isFiltering = false
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.isFiltering = false
                if self.progress != 0 { self.progress = 0 }
                self.task = nil
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
    }

    /// Opening a document stops work but retains any completed comparison.
    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isFiltering = false
        if progress != 0 { progress = 0 }
    }

    func reset() {
        cancel()
        result = nil
        sourceIdentity = nil
        showsFiltered = true
        errorMessage = nil
    }

    func waitUntilFinished() async { await task?.value }
}

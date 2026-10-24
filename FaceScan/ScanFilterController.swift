import Combine
import Foundation

/// Keeps a filtered copy beside the immutable completed scan. A cancelled or
/// superseded worker can never publish its result into a later scan.
@MainActor
final class ScanFilterController: ObservableObject {
    typealias Processor = @Sendable (ScanMesh, ScanFilterSettings) async throws -> ScanFilterResult

    @Published private(set) var result: ScanFilterResult?
    @Published private(set) var isFiltering = false
    @Published var showsFiltered = true
    @Published var errorMessage: String?

    private var sourceIdentity: UUID?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private let processor: Processor

    init(processor: @escaping Processor = { try await ScanPointCloudFilter.processAsync($0, settings: $1) }) {
        self.processor = processor
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
            return
        }
        if sourceIdentity != source.renderIdentity { reset() }
        else { cancel() }
        errorMessage = nil
        sourceIdentity = source.renderIdentity
        isFiltering = true
        let token = generation
        let process = processor
        task = Task { [weak self] in
            do {
                let output = try await process(source, settings)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.result = ScanFilterResult(mesh: output.mesh, statistics: output.statistics, settings: settings)
                self.showsFiltered = true
                self.isFiltering = false
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.isFiltering = false
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

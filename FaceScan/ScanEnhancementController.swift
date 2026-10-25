import Combine
import Foundation

/// Enhanced vertices are a display copy. The scan passed to filtering and PLY
/// export is never replaced, and every cache entry belongs to one exact source.
@MainActor
final class ScanEnhancementController: ObservableObject {
    struct Presentation: Sendable {
        let sourceIdentity: UUID
        let settings: ScanEnhancementSettings
        let mesh: ScanMesh
        let statistics: PointCloudEnhancementResult
    }

    typealias Processor = @Sendable (ScanMesh, ScanEnhancementSettings) async throws -> PointCloudEnhancementResult

    @Published private(set) var presentation: Presentation?
    @Published private(set) var isProcessing = false
    @Published var errorMessage: String?

    private let processor: Processor
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var pendingSource: UUID?
    private var pendingSettings: ScanEnhancementSettings?
    private var cache: [Presentation] = []

    init(processor: @escaping Processor = {
        try await PointCloudDisplayEnhancer.processAsync($0.vertices, settings: $1)
    }) {
        self.processor = processor
    }

    deinit { task?.cancel() }

    func result(for source: ScanMesh) -> Presentation? {
        presentation?.sourceIdentity == source.renderIdentity ? presentation : nil
    }

    func displayedMesh(for source: ScanMesh, isEnabled: Bool) -> ScanMesh {
        isEnabled ? result(for: source)?.mesh ?? source : source
    }

    func start(_ source: ScanMesh, settings: ScanEnhancementSettings) {
        if isProcessing, pendingSource == source.renderIdentity, pendingSettings == settings { return }
        cancel()
        errorMessage = nil
        if let index = cache.firstIndex(where: { $0.sourceIdentity == source.renderIdentity && $0.settings == settings }) {
            let cached = cache.remove(at: index)
            cache.append(cached)
            presentation = cached
            return
        }
        if presentation?.sourceIdentity != source.renderIdentity { presentation = nil }
        pendingSource = source.renderIdentity
        pendingSettings = settings
        isProcessing = true
        let token = generation
        let process = processor
        task = Task { [weak self] in
            do {
                let output = try await process(source, settings)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                // The display copy has no measured triangle topology; filtering
                // and export still receive `source`, including its metadata.
                let displayed = ScanMesh(vertices: output.vertices, triangleIndices: [],
                                         frameCount: source.frameCount, coveredAngles: source.coveredAngles,
                                         isSample: source.isSample, isFiltered: source.isFiltered,
                                         filterSettings: source.filterSettings)
                let result = Presentation(sourceIdentity: source.renderIdentity, settings: settings,
                                          mesh: displayed, statistics: output)
                self.presentation = result
                self.cache.removeAll { $0.sourceIdentity == source.renderIdentity }
                self.cache.append(result)
                if self.cache.count > 2 { self.cache.removeFirst(self.cache.count - 2) }
                self.finish()
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.finish()
                if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        finish()
    }

    func reset() {
        cancel()
        cache.removeAll()
        presentation = nil
        errorMessage = nil
    }

    func waitUntilFinished() async { await task?.value }

    private func finish() {
        task = nil
        isProcessing = false
        pendingSource = nil
        pendingSettings = nil
    }
}

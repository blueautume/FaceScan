import Foundation
import QuartzCore
import os

/// One running preparation and one replaceable pending input. No UI or ARFrames
/// cross this queue; only immutable copies of the measured vertex arrays do.
@MainActor
final class PointCloudRenderPipeline {
    struct Input: Sendable {
        let vertices: [ScanVertex]
        var triangleIndices: [UInt32] = []
        var animates = false
    }

    private struct Request {
        let generation: UInt64
        let sequence: UInt64
        let input: Input
        let completion: @MainActor (PointCloudRenderData) -> Void
    }

    private final class Worker: @unchecked Sendable {
        let queue = DispatchQueue(label: "FaceScan.render-preparation", qos: .userInitiated)
        let builder = PointCloudRenderDataBuilder()
        var generation: UInt64?
        let log = OSLog(subsystem: "top.furby.FaceScan", category: .pointsOfInterest)

        func prepare(_ input: Input, generation: UInt64) -> PointCloudRenderData {
            dispatchPrecondition(condition: .onQueue(queue))
            if self.generation != generation {
                builder.reset()
                self.generation = generation
            }
            os_signpost(.begin, log: log, name: "Prepare Point Cloud")
            defer { os_signpost(.end, log: log, name: "Prepare Point Cloud") }
            _ = PointCloudAnimationTime.origin
            builder.beginPreparation()
            return builder.prepare(vertices: input.vertices, triangleIndices: input.triangleIndices,
                                   animates: input.animates, time: CACurrentMediaTime())
        }
    }

    private let worker = Worker()
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var running: Request?
    private var pending: Request?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func submit(_ input: Input, completion: @escaping @MainActor (PointCloudRenderData) -> Void) {
        sequence &+= 1
        let request = Request(generation: generation, sequence: sequence,
                              input: input, completion: completion)
        if running == nil { start(request) }
        else { pending = request }
    }

    func reset() {
        generation &+= 1
        pending = nil
        resumeWaitersIfIdle()
    }

    func waitUntilIdle() async {
        guard running != nil || pending != nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func start(_ request: Request) {
        running = request
        let worker = worker
        worker.queue.async { [weak self] in
            let data = worker.prepare(request.input, generation: request.generation)
            DispatchQueue.main.async { [weak self] in self?.complete(request, data: data) }
        }
    }

    private func complete(_ request: Request, data: PointCloudRenderData) {
        running = nil
        let accepted = request.generation == generation && request.sequence == sequence
        let worker = worker
        worker.queue.async { worker.builder.finishPreparation(accepted: accepted) }
        if accepted {
            request.completion(data)
        }
        if running == nil, let next = pending {
            pending = nil
            start(next)
        }
        resumeWaitersIfIdle()
    }

    private func resumeWaitersIfIdle() {
        guard running == nil, pending == nil else { return }
        let continuations = waiters
        waiters.removeAll(keepingCapacity: true)
        continuations.forEach { $0.resume() }
    }
}

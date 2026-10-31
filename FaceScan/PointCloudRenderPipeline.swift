import Foundation
import QuartzCore
import os

/// One running preparation and one replaceable pending input. No UI or ARFrames
/// cross this queue; only immutable copies of the measured vertex arrays do.
@MainActor
final class PointCloudRenderPipeline {
    struct Input: Sendable {
        let vertices: [ScanVertex]
        var pointIDs: [UInt64]? = nil
        var triangleIndices: [UInt32] = []
        var animates = false
    }

    private struct Request {
        let generation: UInt64
        let sequence: UInt64
        let input: Input
        let present: @MainActor (PointCloudRenderData) -> TimeInterval?
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
            return builder.prepare(vertices: input.vertices, pointIDs: input.pointIDs,
                                   triangleIndices: input.triangleIndices,
                                   animates: input.animates, time: CACurrentMediaTime())
        }
    }

    private let worker = Worker()
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var running: Request?
    private var pending: Request?
    private var lastPresentedSequence: UInt64?
    private var pendingAcknowledgements = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func submit(_ input: Input, completion: @escaping @MainActor (PointCloudRenderData) -> Void) {
        submitForPresentation(input, present: { data in
            completion(data)
            return CACurrentMediaTime()
        })
    }

    /// Return the timestamp of the SCN presentation commit, or nil when the
    /// consumer rejected the frame. Only a presented frame may consume births.
    func submitForPresentation(_ input: Input, present: @escaping @MainActor (PointCloudRenderData) -> TimeInterval?) {
        sequence &+= 1
        let request = Request(generation: generation, sequence: sequence,
                              input: input, present: present)
        if running == nil { start(request) }
        else { pending = request }
    }

    func reset() {
        generation &+= 1
        pending = nil
        lastPresentedSequence = nil
        resumeWaitersIfIdle()
    }

    func waitUntilIdle() async {
        guard running != nil || pending != nil || pendingAcknowledgements > 0 else { return }
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
        // Keep the running slot occupied throughout presentation. A reentrant
        // submit can replace pending work, but cannot start an overlapping job
        // or overtake the birth acknowledgement for the frame being presented.
        let canPresent = request.generation == generation
            && (lastPresentedSequence.map { request.sequence > $0 } ?? true)
        let presentedAt = canPresent ? request.present(data) : nil
        // The consumer may reset or change scans while presenting.
        let accepted = request.generation == generation && presentedAt?.isFinite == true
        if accepted { lastPresentedSequence = request.sequence }
        let worker = worker
        pendingAcknowledgements += 1
        worker.queue.async { [weak self] in
            worker.builder.finishPreparation(accepted: accepted,
                                             presentedAt: accepted ? presentedAt : nil)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingAcknowledgements -= 1
                self.resumeWaitersIfIdle()
            }
        }
        running = nil
        if let next = pending {
            pending = nil
            start(next)
        }
        resumeWaitersIfIdle()
    }

    private func resumeWaitersIfIdle() {
        guard running == nil, pending == nil, pendingAcknowledgements == 0 else { return }
        let continuations = waiters
        waiters.removeAll(keepingCapacity: true)
        continuations.forEach { $0.resume() }
    }
}

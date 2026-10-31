import QuartzCore
import XCTest
@testable import FaceScan

final class PointCloudRenderPipelineTests: XCTestCase {
    @MainActor
    func testCompletionCanSubmitReplacementWorkWithoutOverlappingPreparation() async {
        let pipeline = PointCloudRenderPipeline()
        let input = PointCloudRenderPipeline.Input(vertices: [
            ScanVertex(position: .zero, color: SIMD3(repeating: 0.5))
        ], animates: true)
        var completed: [Int] = []
        pipeline.submit(input) { _ in
            completed.append(0)
            pipeline.submit(input) { _ in completed.append(1) }
            pipeline.submit(input) { _ in completed.append(2) }
        }
        await pipeline.waitUntilIdle()
        XCTAssertEqual(completed, [0, 2], "Only the latest pending input may follow a reentrant completion.")
    }

    @MainActor
    func testLatestPendingInputDoesNotStarveTheValidRunningFrame() async {
        let pipeline = PointCloudRenderPipeline()
        let input = fixture()
        var presented: [Int] = []
        // No suspension allows an async completion onto the main actor until
        // all three requests have been submitted: the first is definitely busy.
        for index in 0..<3 {
            pipeline.submitForPresentation(input, present: { _ in
                presented.append(index)
                return CACurrentMediaTime()
            })
        }
        await pipeline.waitUntilIdle()
        XCTAssertEqual(presented, [0, 2],
                       "A valid running frame must display even when newer live data is waiting.")
    }

    @MainActor
    func testResetRejectsRunningAndPendingFramesOfThePreviousScan() async {
        let pipeline = PointCloudRenderPipeline()
        let input = fixture()
        var presented: [Int] = []
        pipeline.submit(input) { _ in presented.append(0) }
        pipeline.submit(input) { _ in presented.append(1) }
        pipeline.reset()
        pipeline.submit(input) { _ in presented.append(2) }
        await pipeline.waitUntilIdle()
        XCTAssertEqual(presented, [2])
    }

    @MainActor
    func testReentrantResetKeepsOnlyTheNewGenerationPendingInput() async {
        let pipeline = PointCloudRenderPipeline()
        let input = fixture()
        var presented: [Int] = []
        pipeline.submitForPresentation(input, present: { _ in
            presented.append(0)
            pipeline.submit(input) { _ in presented.append(1) }
            pipeline.reset()
            pipeline.submit(input) { _ in presented.append(2) }
            return CACurrentMediaTime()
        })
        await pipeline.waitUntilIdle()
        XCTAssertEqual(presented, [0, 2], "Reset inside a consumer must not run stale pending work.")
    }

    @MainActor
    func testOnlyPresentedFramesCommitBirthsAtTheirPresentationTimestamp() async throws {
        let pipeline = PointCloudRenderPipeline()
        let input = fixture()
        var rejectedBirth: Float?
        pipeline.submitForPresentation(input, present: { data in
            rejectedBirth = self.birth(in: data)
            return nil
        })
        await pipeline.waitUntilIdle()
        XCTAssertLessThan(try XCTUnwrap(rejectedBirth), 0)

        var acceptedBirth: Float?
        var expectedHistoricalBirth: Float?
        pipeline.submitForPresentation(input, present: { data in
            acceptedBirth = self.birth(in: data)
            // Simulate packing/dispatch delay without sleeps. The birth must
            // be committed relative to presentation, not preparation time.
            let presentedAt = data.preparationTime + 2
            if let pending = acceptedBirth {
                expectedHistoricalBirth = PointCloudAnimationTime.shaderTime(at: presentedAt) + (-pending - 1)
            }
            return presentedAt
        })
        await pipeline.waitUntilIdle()
        XCTAssertLessThan(try XCTUnwrap(acceptedBirth), 0,
                          "A frame the consumer rejected must not consume a new particle's birth.")

        var historicalBirth: Float?
        pipeline.submitForPresentation(input, present: { data in
            historicalBirth = self.birth(in: data)
            return CACurrentMediaTime()
        })
        await pipeline.waitUntilIdle()
        XCTAssertEqual(try XCTUnwrap(historicalBirth), try XCTUnwrap(expectedHistoricalBirth), accuracy: 0.0001,
                       "The stable point ID must retain the acknowledged presentation-time birth.")
    }

    private func fixture() -> PointCloudRenderPipeline.Input {
        PointCloudRenderPipeline.Input(vertices: [
            ScanVertex(position: .zero, color: SIMD3(repeating: 0.5))
        ], pointIDs: [42], animates: true)
    }

    private func birth(in data: PointCloudRenderData) -> Float? {
        guard let bytes = data.birthData, bytes.count >= MemoryLayout<Float>.size else { return nil }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }
}

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
}

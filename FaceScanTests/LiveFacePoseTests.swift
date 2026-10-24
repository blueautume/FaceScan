import XCTest
import simd
@testable import FaceScan

final class LiveFacePoseTests: XCTestCase {
    func testHeadRotationStaysAbsoluteAndTranslationIsRelativeToScanStart() throws {
        let store = LiveFacePoseStore()
        var initial = simd_float4x4(simd_quatf(angle: 0.2, axis: SIMD3(0, 1, 0)))
        initial.columns.3 = SIMD4(0.03, -0.02, -0.4, 1)
        XCTAssertTrue(store.update(faceToCamera: initial))
        let first = try XCTUnwrap(store.latestPose)
        XCTAssertEqual(first.transform.columns.0, initial.columns.0,
                       "A turned head must not be flattened to a neutral first-frame angle.")
        XCTAssertEqual(first.transform.columns.3, SIMD4(0, 0, 0, 1))

        var moved = simd_float4x4(simd_quatf(angle: -0.4, axis: SIMD3(0, 1, 0)))
        moved.columns.3 = SIMD4(0.05, -0.01, -0.35, 1)
        XCTAssertTrue(store.update(faceToCamera: moved))
        let second = try XCTUnwrap(store.latestPose)
        XCTAssertGreaterThan(second.revision, first.revision)
        XCTAssertEqual(second.transform.columns.0, moved.columns.0)
        XCTAssertEqual(second.transform.columns.3.x, 0.02, accuracy: 0.00001)
        XCTAssertEqual(second.transform.columns.3.y, 0.01, accuracy: 0.00001)
        XCTAssertEqual(second.transform.columns.3.z, 0.05, accuracy: 0.00001)
    }

    func testResetRecentersTheNextScanWithoutReusingPoseRevision() throws {
        let store = LiveFacePoseStore()
        store.update(faceToCamera: matrix_identity_float4x4)
        let oldRevision = try XCTUnwrap(store.latestPose).revision
        store.reset()
        XCTAssertNil(store.latestPose)
        var next = matrix_identity_float4x4
        next.columns.3 = SIMD4(-0.12, 0.03, -0.5, 1)
        store.update(faceToCamera: next)
        let pose = try XCTUnwrap(store.latestPose)
        XCTAssertGreaterThan(pose.revision, oldRevision)
        XCTAssertEqual(pose.transform.columns.3, SIMD4(0, 0, 0, 1))
    }

    func testMalformedPoseCannotReplaceTheLastValidPose() throws {
        let store = LiveFacePoseStore()
        store.update(faceToCamera: matrix_identity_float4x4)
        let good = try XCTUnwrap(store.latestPose)
        var invalidTransforms: [simd_float4x4] = []
        var invalid = matrix_identity_float4x4
        invalid.columns.3.x = .nan
        invalidTransforms.append(invalid)
        invalid = matrix_identity_float4x4
        invalid.columns.0.x = 2
        invalidTransforms.append(invalid)
        invalid.columns.0.x = -1
        invalidTransforms.append(invalid)
        invalid = matrix_identity_float4x4
        invalid.columns.3.w = 0
        invalidTransforms.append(invalid)
        for transform in invalidTransforms {
            XCTAssertFalse(store.update(faceToCamera: transform))
            XCTAssertEqual(store.latestPose?.revision, good.revision)
            XCTAssertEqual(store.latestPose?.transform, good.transform)
        }
    }

    func testConcurrentReadsAndWritesKeepCompleteTransforms() {
        let store = LiveFacePoseStore()
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            let rotation = simd_float4x4(simd_quatf(angle: Float(index) / 1_000,
                                                   axis: SIMD3(0, 1, 0)))
            XCTAssertTrue(store.update(faceToCamera: rotation))
            guard let pose = store.latestPose else { return XCTFail("A completed write must remain readable.") }
            XCTAssertEqual(pose.transform.columns.3, SIMD4(0, 0, 0, 1))
            XCTAssertEqual(simd_length(pose.transform.columns.0), 1, accuracy: 0.00001)
        }
        XCTAssertEqual(store.latestPose?.revision, 1_000)
    }
}

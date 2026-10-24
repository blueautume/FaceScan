import CoreGraphics
import simd
import XCTest
@testable import FaceScan

final class DepthGeometryTests: XCTestCase {
    func testPrincipalPointBackProjectsToOpticalZAxisInMeters() throws {
        let projection = try XCTUnwrap(DepthProjection(
            intrinsics: intrinsics(fx: 500, fy: 510, cx: 320.5, cy: 240.5),
            referenceSize: CGSize(width: 640, height: 480),
            depthSize: CGSize(width: 640, height: 480)))

        let point = projection.point(x: 320, y: 240, depth: 0.4)

        assertVector(point, equals: SIMD3(0, 0, 0.4))
    }

    func testIntrinsicsReferenceDimensionsScaleToDepthResolution() throws {
        let matrix = intrinsics(fx: 500, fy: 600, cx: 320, cy: 240)
        let halfSize = try XCTUnwrap(DepthProjection(
            intrinsics: matrix, referenceSize: CGSize(width: 640, height: 480),
            depthSize: CGSize(width: 320, height: 240)))
        let fullSize = try XCTUnwrap(DepthProjection(
            intrinsics: matrix, referenceSize: CGSize(width: 640, height: 480),
            depthSize: CGSize(width: 640, height: 480)))

        // Both are exactly the same optical ray: (210, 150) depth coordinates
        // correspond to (420, 300) calibration-reference coordinates.
        let point = halfSize.point(pixelCenter: SIMD2(210, 150), depth: 0.5)
        let reference = fullSize.point(pixelCenter: SIMD2(420, 300), depth: 0.5)

        assertVector(point, equals: SIMD3(0.1, 0.05, 0.5))
        assertVector(point, equals: reference)
    }

    func testEachDepthPixelIsSampledAtItsCenter() throws {
        let projection = try XCTUnwrap(DepthProjection(
            intrinsics: intrinsics(fx: 500, fy: 500, cx: 320, cy: 240),
            referenceSize: CGSize(width: 640, height: 480),
            depthSize: CGSize(width: 320, height: 240)))

        let point = projection.point(x: 200, y: 150, depth: 0.5)

        assertVector(point, equals: SIMD3(0.081, 0.061, 0.5))
    }

    func testOpticalAxesFlipToARKitCameraAxes() {
        let optical = SIMD3<Float>(0.02, 0.03, 0.4)

        let cameraPoint = DepthGeometry.opticalToARCamera(optical)

        assertVector(cameraPoint, equals: SIMD3(0.02, -0.03, -0.4))
    }

    func testCameraAndFaceRigidTransformsRecoverSamePhysicalPoint() {
        let faceTransform = rigidTransform(angle: 0.28, translation: SIMD3(0.11, 0.04, -0.48))
        let cameraTransform = rigidTransform(angle: -0.12, translation: SIMD3(-0.03, 0.02, 0.01))
        let expectedFacePoint = SIMD3<Float>(0.025, -0.015, 0.035)
        let world = faceTransform * SIMD4(expectedFacePoint.x, expectedFacePoint.y, expectedFacePoint.z, 1)
        let cameraPoint = simd_inverse(cameraTransform) * world
        // Optical +Z forward/+Y down is the inverse of the same ARKit axis flip.
        let optical = SIMD3(cameraPoint.x, -cameraPoint.y, -cameraPoint.z)
        let cameraToFace = simd_inverse(faceTransform) * cameraTransform

        let reconstructed = DepthGeometry.facePoint(fromOptical: optical, cameraToFace: cameraToFace)

        assertVector(reconstructed, equals: expectedFacePoint)
    }

    func testInverseDistortionTableCorrectsExistingSensorPixel() throws {
        let projection = try XCTUnwrap(DepthProjection(
            intrinsics: intrinsics(fx: 100, fy: 100, cx: 200, cy: 200),
            referenceSize: CGSize(width: 400, height: 400),
            depthSize: CGSize(width: 400, height: 400),
            distortionCenter: CGPoint(x: 200, y: 200),
            inverseDistortion: [0.1, 0.1]))

        let point = projection.point(pixelCenter: SIMD2(300, 200), depth: 0.5)

        assertVector(point, equals: SIMD3(0.55, 0, 0.5))
    }

    func testInvalidCalibrationIsRejected() {
        XCTAssertNil(DepthProjection(intrinsics: matrix_identity_float3x3,
                                    referenceSize: CGSize(width: 640, height: 480),
                                    depthSize: .zero))
        XCTAssertNil(DepthProjection(intrinsics: simd_float3x3(0),
                                    referenceSize: CGSize(width: 640, height: 480),
                                    depthSize: CGSize(width: 320, height: 240)))
    }

    private func intrinsics(fx: Float, fy: Float, cx: Float, cy: Float) -> simd_float3x3 {
        simd_float3x3(columns: (SIMD3(fx, 0, 0), SIMD3(0, fy, 0), SIMD3(cx, cy, 1)))
    }

    private func rigidTransform(angle: Float, translation: SIMD3<Float>) -> simd_float4x4 {
        var matrix = simd_float4x4(simd_quatf(angle: angle, axis: SIMD3(0, 1, 0)))
        matrix.columns.3 = SIMD4(translation.x, translation.y, translation.z, 1)
        return matrix
    }

    private func assertVector(_ actual: SIMD3<Float>, equals expected: SIMD3<Float>,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: 0.000001, file: file, line: line)
    }
}

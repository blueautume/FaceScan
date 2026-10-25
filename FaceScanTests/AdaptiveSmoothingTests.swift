import XCTest
@testable import FaceScan

final class AdaptiveSmoothingTests: XCTestCase {
    func testCurveUsesFixedKnotsSmoothInterpolationAndBoundedEndpoints() {
        let curve = FaceCloudSmoothingCurve.featurePreserving
        XCTAssertTrue(curve.isValid)
        XCTAssertEqual(curve.strength(for: -1), 1)
        XCTAssertEqual(curve.strength(for: 1), 0)
        for index in 0..<5 {
            XCTAssertEqual(curve.strength(for: Double(index) * curve.maximumVariation / 4),
                           curve.strengths[index], accuracy: 1e-14)
        }
        let linear = curve.strengths[0] + (curve.strengths[1] - curve.strengths[0]) * 0.125
        XCTAssertGreaterThan(curve.strength(for: curve.maximumVariation / 32), linear,
                             "The control connects knots with a nonlinear easing curve.")
        let arbitrary = FaceCloudSmoothingCurve(strengths: [0.1, 0.9, 0.2, 0.8, 0.3])
        for index in 0...400 {
            let x = Double(index) / 400
            let segment = min(3, Int(x * 4))
            let bounds = [arbitrary.strengths[segment], arbitrary.strengths[segment + 1]]
            let value = arbitrary.strength(for: x * arbitrary.maximumVariation)
            XCTAssertGreaterThanOrEqual(value, bounds.min()! - 1e-14)
            XCTAssertLessThanOrEqual(value, bounds.max()! + 1e-14)
        }
    }

    func testInvalidCurvesAreRejectedBeforeProcessing() throws {
        let invalid = [
            FaceCloudSmoothingCurve(strengths: [1, 0]),
            FaceCloudSmoothingCurve(strengths: [1, 0.8, .nan, 0.2, 0]),
            FaceCloudSmoothingCurve(strengths: [1, 0.8, 0.5, 0.2, -0.1]),
            FaceCloudSmoothingCurve(maximumVariation: 0),
            FaceCloudSmoothingCurve(neighborhoodRadius: .infinity)
        ]
        for curve in invalid {
            XCTAssertFalse(curve.isValid)
            var configuration = FaceCloudConfiguration.reference
            configuration.smoothingCurve = curve
            XCTAssertThrowsError(try FacePointCloudProcessor.process(legacyFixture(), configuration: configuration)) {
                guard case FaceCloudProcessingError.invalidConfiguration = $0 else {
                    return XCTFail("Expected invalid curve configuration, got \($0)")
                }
            }
        }
    }

    func testDisabledCurveMatchesCommittedLegacyGoldenAndUniformFullStrength() throws {
        let input = legacyFixture()
        let baseline = try FacePointCloudProcessor.process(input)
        // Generated from the committed 8f851e9 processor, before curve support.
        XCTAssertEqual(baseline.points.count, 77)
        XCTAssertEqual(baseline.statistics.sorRejectedCount, 4)
        XCTAssertEqual(baseline.statistics.modelRejectedCount, 0)
        XCTAssertEqual(fingerprint(baseline), 16_397_871_226_700_290_914)

        var configuration = FaceCloudConfiguration.reference
        configuration.smoothingCurve = FaceCloudSmoothingCurve(strengths: [1, 1, 1, 1, 1])
        let fullStrength = try FacePointCloudProcessor.process(input, configuration: configuration)
        XCTAssertEqual(fingerprint(fullStrength), fingerprint(baseline),
                       "A horizontal 100% curve must preserve the legacy result, including sparse boundaries and RGB.")
    }

    func testZeroCurveRetainsExactSourcePositionsAndAppliesDisplacementGateAfterBlending() throws {
        let input = legacyFixture()
        var configuration = FaceCloudConfiguration.reference
        configuration.filterColors = false
        let baseline = try FacePointCloudProcessor.process(input, configuration: configuration)
        configuration.smoothingCurve = FaceCloudSmoothingCurve(strengths: [0, 0, 0, 0, 0])
        configuration.maximumRadialDisplacement = 0
        let protected = try FacePointCloudProcessor.process(input, configuration: configuration)
        XCTAssertEqual(protected.sourceIndices, baseline.sourceIndices)
        XCTAssertEqual(protected.statistics.sorRejectedCount, baseline.statistics.sorRejectedCount,
                       "The geometry curve must not silently disable SOR.")
        XCTAssertEqual(protected.statistics.modelRejectedCount, 0)
        XCTAssertEqual(protected.statistics.maximumDisplacementMM, 0)
        for (point, source) in zip(protected.points, protected.sourceIndices) {
            XCTAssertEqual(point.position, input[source].position)
            XCTAssertEqual(point.position.x.bitPattern, input[source].position.x.bitPattern)
            XCTAssertEqual(point.position.y.bitPattern, input[source].position.y.bitPattern)
            XCTAssertEqual(point.position.z.bitPattern, input[source].position.z.bitPattern)
            XCTAssertEqual(point.color, input[source].color)
        }
    }

    func testAdaptiveCurveSmoothsSkinNoiseWhileProtectingSharpRidge() throws {
        let input = skinAndRidgeFixture()
        var configuration = smoothingConfiguration()
        let baseline = try FacePointCloudProcessor.process(input, configuration: configuration)
        configuration.smoothingCurve = FaceCloudSmoothingCurve(
            strengths: [1, 1, 0.2, 0, 0], maximumVariation: 0.0015, neighborhoodRadius: 0.004)
        let adaptive = try FacePointCloudProcessor.process(input, configuration: configuration)
        let baselineBySource = Dictionary(uniqueKeysWithValues: zip(baseline.sourceIndices, baseline.points))
        var ridgeOriginalMovement = 0.0, ridgeAdaptiveMovement = 0.0
        var flatOriginalError = 0.0, flatAdaptiveError = 0.0
        var flatCount = 0, ridgeCount = 0
        for (source, point) in zip(adaptive.sourceIndices, adaptive.points) {
            let row = source / 81 - 20, column = source % 81 - 40
            guard abs(row) <= 10, let full = baselineBySource[source] else { continue }
            if abs(column) <= 2 {
                ridgeOriginalMovement += abs(radius(full.position) - radius(input[source].position))
                ridgeAdaptiveMovement += abs(radius(point.position) - radius(input[source].position))
                ridgeCount += 1
            }
            if column < -20 && column > -35 {
                flatOriginalError += abs(radius(input[source].position) - 0.1)
                flatAdaptiveError += abs(radius(point.position) - 0.1)
                flatCount += 1
            }
        }
        XCTAssertGreaterThan(ridgeCount, 50)
        XCTAssertGreaterThan(flatCount, 100)
        XCTAssertGreaterThan(ridgeOriginalMovement / Double(ridgeCount), 0.001,
                             "The fixture must contain a ridge the full filter would flatten.")
        XCTAssertLessThan(ridgeAdaptiveMovement, ridgeOriginalMovement * 0.25)
        XCTAssertLessThan(flatAdaptiveError, flatOriginalError * 0.5,
                          "Low-variation skin should still be smoothed, rather than bypassing all geometry.")
    }

    func testVariationRemovesLocalTiltAndWrapsAcrossThetaSeam() throws {
        let nu = 32, nv = 11
        var radii = [Double](repeating: 0, count: nu * nv)
        for u in 0..<nu {
            let signedU = u <= nu / 2 ? u : u - nu
            for v in 0..<nv { radii[u * nv + v] = 0.1 + Double(signedU) * 0.0004 + Double(v) * 0.0002 }
        }
        let observed = [Bool](repeating: true, count: radii.count)
        let seam = nv / 2
        let sloping = try FPCAdaptiveSmoothing.localVariation(
            radii: radii, observed: observed, active: Array(radii.indices), nu: nu, nv: nv,
            du: 0.001, dv: 0.001, radius: 0.0035)
        XCTAssertLessThan(try XCTUnwrap(sloping[seam].isFinite ? sloping[seam] : nil), 1e-9,
                          "A sloping but locally flat surface must not be protected as a facial feature, including at the periodic seam.")
        radii[seam] += 0.004
        let curved = try FPCAdaptiveSmoothing.localVariation(
            radii: radii, observed: observed, active: Array(radii.indices), nu: nu, nv: nv,
            du: 0.001, dv: 0.001, radius: 0.0035)
        XCTAssertGreaterThan(curved[seam], 0.0004)
    }

    func testSparseUnsupportedPatchKeepsSourceAndAnalysisCanBeCancelled() throws {
        var input: [FaceCloudPoint] = []
        for column in 0..<41 {
            let x = Float(column - 20) * 0.001
            let z = 0.05 + Float(column % 3 - 1) * 0.0005
            input.append(FaceCloudPoint(position: SIMD3(x, 0, z), color: SIMD3(100, 120, 140)))
        }
        var configuration = smoothingConfiguration()
        configuration.smoothingCurve = .featurePreserving
        let protected = try FacePointCloudProcessor.process(input, configuration: configuration)
        for (point, source) in zip(protected.points, protected.sourceIndices) {
            XCTAssertEqual(point.position, input[source].position,
                           "One observed row cannot support a 2D local plane and should retain its geometry.")
        }
        XCTAssertThrowsError(try FPCAdaptiveSmoothing.localVariation(
            radii: [0.1], observed: [true], active: [0], nu: 1, nv: 1,
            du: 0.001, dv: 0.001, radius: 0.004,
            checkCancellation: { throw CancellationError() })) {
                XCTAssertTrue($0 is CancellationError)
            }
    }

    private func legacyFixture() -> [FaceCloudPoint] {
        var input: [FaceCloudPoint] = []
        for row in 0..<9 {
            for column in 0..<9 {
                let index = row * 9 + column
                let x = Float(column - 4) / 512, y = Float(row - 4) / 512
                let noise = Float(index * 7 % 5 - 2) / 4096
                let ridge: Float = column == 4 ? 1.0 / 512 : 0
                input.append(FaceCloudPoint(position: SIMD3(x, y, 1.0 / 16 + noise + ridge),
                                            color: SIMD3(UInt8(index * 13 % 256), UInt8(index * 7 % 256), 128)))
            }
        }
        return input
    }

    private func skinAndRidgeFixture() -> [FaceCloudPoint] {
        var input: [FaceCloudPoint] = []
        for row in -20...20 {
            for column in -40...40 {
                let u = Double(column) * 0.00075, y = Double(row) * 0.00075
                let noise = 0.0003 * sin(Double((row + 20) * 81 + column + 40) * 2.37)
                let ridge = 0.006 * exp(-u * u / (2 * 0.0015 * 0.0015))
                let r = 0.1 + noise + ridge, theta = u / 0.1
                input.append(FaceCloudPoint(position: SIMD3(Float(r * sin(theta)), Float(y), Float(-0.05 + r * cos(theta))),
                                            color: SIMD3(100, 150, 200)))
            }
        }
        return input
    }

    private func smoothingConfiguration() -> FaceCloudConfiguration {
        var configuration = FaceCloudConfiguration.reference
        configuration.parameterGridSize = 0.00075
        configuration.bilateralRadiusSigma = 0.01
        configuration.maximumRadialDisplacement = 0.04
        configuration.filterColors = false
        configuration.sorStandardDeviations = 8
        return configuration
    }

    private func radius(_ p: SIMD3<Float>) -> Double { hypot(Double(p.x), Double(p.z) + 0.05) }

    private func fingerprint(_ result: FaceCloudResult) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func byte(_ value: UInt8) { hash = (hash ^ UInt64(value)) &* 1_099_511_628_211 }
        func word(_ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) { byte(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        for (point, source) in zip(result.points, result.sourceIndices) {
            word(point.position.x.bitPattern); word(point.position.y.bitPattern); word(point.position.z.bitPattern)
            byte(point.color.x); byte(point.color.y); byte(point.color.z); word(UInt32(source))
        }
        return hash
    }
}

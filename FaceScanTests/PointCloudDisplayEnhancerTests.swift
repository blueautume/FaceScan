import XCTest
import simd
@testable import FaceScan

final class PointCloudDisplayEnhancerTests: XCTestCase {
    func testFlatPatchDensifiesOnSurfaceAndRetainsEverySourceExactly() throws {
        let source = flatPatch()
        var settings = ScanEnhancementSettings()
        settings.maximumPointCount = 1_000
        let result = try PointCloudDisplayEnhancer.process(source, settings: settings)

        XCTAssertEqual(result.originalPointCount, source.count)
        XCTAssertGreaterThan(result.addedPointCount, 20)
        XCTAssertEqual(result.vertices.count, source.count + result.addedPointCount)
        for index in source.indices {
            XCTAssertEqual(result.vertices[index].position, source[index].position)
            XCTAssertEqual(result.vertices[index].color, source[index].color)
        }
        for index in source.count..<result.vertices.count {
            let vertex = result.vertices[index]
            XCTAssertEqual(vertex.position.z, 0.04, accuracy: 1e-7)
            XCTAssertGreaterThanOrEqual(vertex.position.x, -0.01)
            XCTAssertLessThanOrEqual(vertex.position.x, 0.01)
            XCTAssertGreaterThanOrEqual(vertex.position.y, -0.01)
            XCTAssertLessThanOrEqual(vertex.position.y, 0.01)
            for prior in 0..<index {
                XCTAssertGreaterThanOrEqual(simd_distance(vertex.position, result.vertices[prior].position),
                                            settings.targetSpacing - 1e-8,
                                            "A generated point must respect spacing from all original and generated points.")
            }
        }
    }

    func testFixedSeedIsStableAndSpacingControlsDensity() throws {
        let source = flatPatch()
        var settings = ScanEnhancementSettings()
        settings.maximumPointCount = 1_000
        let first = try PointCloudDisplayEnhancer.process(source, settings: settings)
        let repeated = try PointCloudDisplayEnhancer.process(source, settings: settings)
        XCTAssertEqual(first.vertices.map(\.position), repeated.vertices.map(\.position))
        XCTAssertEqual(first.vertices.map(\.color), repeated.vertices.map(\.color))
        settings.targetSpacing = 0.0012
        let coarser = try PointCloudDisplayEnhancer.process(source, settings: settings)
        XCTAssertLessThan(coarser.addedPointCount, first.addedPointCount)
        settings.targetSpacing = 0.0008
        settings.seed &+= 1
        let otherSeed = try PointCloudDisplayEnhancer.process(source, settings: settings)
        XCTAssertNotEqual(otherSeed.vertices.dropFirst(source.count).map(\.position),
                          first.vertices.dropFirst(source.count).map(\.position))
    }

    func testBudgetCapsAdditionsAndNeverDropsOriginalMeasurements() throws {
        let source = flatPatch()
        var settings = ScanEnhancementSettings()
        settings.maximumPointCount = source.count + 8
        let limited = try PointCloudDisplayEnhancer.process(source, settings: settings)
        XCTAssertEqual(limited.vertices.count, source.count + 8)
        XCTAssertEqual(limited.addedPointCount, 8)
        XCTAssertTrue(limited.reachedLimit)
        settings.maximumPointCount = source.count - 1
        let alreadyOverBudget = try PointCloudDisplayEnhancer.process(source, settings: settings)
        XCTAssertEqual(alreadyOverBudget.vertices.map(\.position), source.map(\.position))
        XCTAssertEqual(alreadyOverBudget.addedPointCount, 0)
        XCTAssertTrue(alreadyOverBudget.reachedLimit)
    }

    func testLargeUnsupportedGapAndColorBoundaryAreNotBridged() throws {
        var disconnected: [ScanVertex] = []
        for y in -4...4 {
            for side: Float in [-1, 1] {
                for x in 0...5 {
                    disconnected.append(ScanVertex(position: SIMD3(side * (0.004 + Float(x) * 0.002),
                                                                 Float(y) * 0.002, 0.04),
                                                   color: SIMD3(0.4, 0.5, 0.6)))
                }
            }
        }
        let gap = try PointCloudDisplayEnhancer.process(disconnected, settings: ScanEnhancementSettings())
        XCTAssertGreaterThan(gap.addedPointCount, 0)
        XCTAssertTrue(gap.vertices.dropFirst(disconnected.count).allSatisfy { abs($0.position.x) >= 0.004 - 1e-7 },
                      "Supported fans must not extrapolate across the unsampled gap.")

        let boundary = flatPatch().map { vertex in
            ScanVertex(position: vertex.position,
                       color: vertex.position.x < 0 ? SIMD3(1, 0.1, 0.1) : SIMD3(0.1, 0.1, 1))
        }
        let colors = try PointCloudDisplayEnhancer.process(boundary, settings: ScanEnhancementSettings())
        XCTAssertGreaterThan(colors.addedPointCount, 0)
        for vertex in colors.vertices.dropFirst(boundary.count) {
            let red = vertex.color.x > 0.9 && vertex.color.z < 0.2
            let blue = vertex.color.z > 0.9 && vertex.color.x < 0.2
            XCTAssertTrue(red || blue, "Local colors must not blend across the protected color boundary.")
        }
    }

    func testSeparatedDepthLayersAndHigherProtectionRemainConservative() throws {
        let stepped = flatPatch().map { vertex in
            var copy = vertex
            if copy.position.x >= 0 { copy.position.z += 0.004 }
            return copy
        }
        let layers = try PointCloudDisplayEnhancer.process(stepped, settings: ScanEnhancementSettings())
        XCTAssertGreaterThan(layers.addedPointCount, 0)
        XCTAssertTrue(layers.vertices.dropFirst(stepped.count).allSatisfy {
            abs($0.position.z - 0.04) < 1e-6 || abs($0.position.z - 0.044) < 1e-6
        }, "New display points must not fill the volume between distinct depth layers.")

        let noisy = flatPatch().enumerated().map { index, vertex in
            var copy = vertex
            copy.position.z += Float(sin(Double(index) * 2.37)) * 0.0003
            return copy
        }
        var loose = ScanEnhancementSettings()
        loose.edgeProtection = 0
        var strict = loose
        strict.edgeProtection = 1
        let low = try PointCloudDisplayEnhancer.process(noisy, settings: loose)
        let high = try PointCloudDisplayEnhancer.process(noisy, settings: strict)
        XCTAssertGreaterThan(low.addedPointCount, 0)
        XCTAssertLessThan(high.addedPointCount, low.addedPointCount,
                          "More edge protection should reject uncertain noisy/curved patches.")
    }

    func testInvalidValuesAndCancellationDoNotReturnAnEnhancedBuffer() async throws {
        var settings = ScanEnhancementSettings()
        settings.targetSpacing = 0
        XCTAssertThrowsError(try PointCloudDisplayEnhancer.process(flatPatch(), settings: settings)) {
            XCTAssertTrue($0 is PointCloudDisplayEnhancer.EnhancementError)
        }
        var invalid = flatPatch()
        invalid[1].position.z = .nan
        XCTAssertThrowsError(try PointCloudDisplayEnhancer.process(invalid, settings: ScanEnhancementSettings())) {
            guard case PointCloudDisplayEnhancer.EnhancementError.invalidVertex(1) = $0 else {
                return XCTFail("Expected finite geometry validation, got \($0)")
            }
        }
        invalid = flatPatch()
        invalid[2].color.y = .infinity
        XCTAssertThrowsError(try PointCloudDisplayEnhancer.process(invalid, settings: ScanEnhancementSettings()))

        let source = flatPatch()
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PointCloudDisplayEnhancer.processAsync(source, settings: ScanEnhancementSettings())
        }
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled enhancement must not return a display result.")
        } catch is CancellationError {}
    }

    func testAsyncUsesTheSameStableSampling() async throws {
        let source = flatPatch()
        let settings = ScanEnhancementSettings()
        let synchronous = try PointCloudDisplayEnhancer.process(source, settings: settings)
        let asynchronous = try await PointCloudDisplayEnhancer.processAsync(source, settings: settings)
        XCTAssertEqual(synchronous.vertices.map(\.position), asynchronous.vertices.map(\.position))
        XCTAssertEqual(synchronous.vertices.map(\.color), asynchronous.vertices.map(\.color))
    }

    private func flatPatch() -> [ScanVertex] {
        var vertices: [ScanVertex] = []
        for row in -5...5 {
            for column in -5...5 {
                vertices.append(ScanVertex(position: SIMD3(Float(column) * 0.002, Float(row) * 0.002, 0.04),
                                           color: SIMD3(0.4, 0.5, 0.6)))
            }
        }
        return vertices
    }
}

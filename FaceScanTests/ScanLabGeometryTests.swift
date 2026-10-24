import XCTest
import simd
@testable import FaceScan

final class ScanLabGeometryTests: XCTestCase {
    func testPreviewFilteringDoesNotMutateCapturedVerticesOrColors() {
        let original = [point(-0.002, 0, 0), point(0, 0, 0.003), point(0.002, 0, 0)]
        let positions = original.map(\.position)
        let colors = original.map(\.color)
        var settings = baseSettings()
        settings.filterEnabled = true
        settings.filterRadius = 0.01
        settings.filterStrength = 1
        let output = ScanLabGeometryProcessor.process(vertices: original, settings: settings)

        XCTAssertEqual(original.map(\.position), positions)
        XCTAssertEqual(original.map(\.color), colors)
        XCTAssertNotEqual(output.vertices.map(\.position), positions)
        XCTAssertEqual(output.vertices.map(\.color), colors)
        XCTAssertEqual(output.sourceIndices, [0, 1, 2])
        XCTAssertEqual(output.originalPointCount, 3)
    }

    func testInvalidPositionsAndColorsAreRemovedWithOriginalIndexMapping() {
        let input = [point(0, 0, 0), point(.nan, 0, 0), point(0, .infinity, 0),
                     ScanVertex(position: .zero, color: SIMD3(.nan, 0, 0)),
                     ScanVertex(position: .zero, color: SIMD3(1.1, 0, 0)),
                     ScanVertex(position: .zero, color: SIMD3(0, -0.1, 0)),
                     point(0.01, 0, 0)]
        let result = ScanLabGeometryProcessor.process(vertices: input, settings: baseSettings())
        XCTAssertEqual(result.sourceIndices, [0, 6])
        XCTAssertEqual(result.originalPointCount, 7)
        XCTAssertEqual(result.normals, [SIMD3(0, 0, 1), SIMD3(0, 0, 1)])
    }

    func testEmptyAndZeroDensityResultsHaveConsistentArrays() {
        var settings = baseSettings()
        settings.filterEnabled = true
        settings.outlierRemovalEnabled = true
        settings.meshEnabled = true
        let empty = ScanLabGeometryProcessor.process(vertices: [], settings: settings)
        XCTAssertTrue(empty.vertices.isEmpty)
        XCTAssertTrue(empty.normals.isEmpty)
        XCTAssertTrue(empty.triangleIndices.isEmpty)
        settings.pointDensity = 0
        let hidden = ScanLabGeometryProcessor.process(vertices: [point(0, 0, 0)], settings: settings)
        XCTAssertTrue(hidden.vertices.isEmpty)
        XCTAssertTrue(hidden.sourceIndices.isEmpty)
        XCTAssertEqual(hidden.originalPointCount, 1)
    }

    func testDensitySamplesAcrossWholeCaptureAndEnforcesDisplayBudget() {
        let input = (0..<50_000).map { point(Float($0) * 0.00001, 0, 0) }
        var settings = baseSettings()
        let capped = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        XCTAssertEqual(capped.vertices.count, 24_000)
        XCTAssertEqual(capped.sourceIndices.first, 0)
        XCTAssertEqual(capped.sourceIndices.last, 49_999)
        XCTAssertEqual(Set(capped.sourceIndices).count, capped.vertices.count)
        XCTAssertEqual(capped.originalPointCount, 50_000)
        settings.pointDensity = 0.1
        let reduced = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        XCTAssertEqual(reduced.vertices.count, 5_000)
        XCTAssertEqual(reduced.sourceIndices.first, 0)
        XCTAssertEqual(reduced.sourceIndices.last, 49_999)
    }

    func testZeroAndHalfFilterStrengthHavePredictableEffect() {
        let input = [point(-0.002, 0, 0), point(0, 0, 0.003), point(0.002, 0, 0)]
        var settings = baseSettings()
        settings.filterEnabled = true
        settings.filterRadius = 0.01
        settings.filterStrength = 0
        let unchanged = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        XCTAssertEqual(unchanged.vertices.map(\.position), input.map(\.position))
        settings.filterStrength = 0.5
        let half = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        XCTAssertEqual(half.vertices[1].position.z, 0.002, accuracy: 0.000001)
        settings.filterStrength = 1
        let full = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        XCTAssertEqual(full.vertices[1].position.z, 0.001, accuracy: 0.000001)
    }

    func testMedianRemovesAnIsolatedDepthSpike() {
        let input = [point(0, 0, 0.004), point(-0.001, 0, 0), point(0.001, 0, 0),
                     point(0, -0.001, 0), point(0, 0.001, 0)]
        var settings = baseSettings()
        settings.filterEnabled = true
        settings.filterMode = .median
        settings.filterRadius = 0.01
        settings.filterStrength = 1
        let output = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        XCTAssertEqual(output.vertices[0].position.z, 0, accuracy: 0.000001)
    }

    func testBilateralPreservesDepthStepBetterThanMean() {
        let input = [point(-0.002, 0, 0), point(-0.001, 0, 0),
                     point(0.001, 0, 0.006), point(0.002, 0, 0.006)]
        var settings = baseSettings()
        settings.filterEnabled = true
        settings.filterStrength = 1
        settings.filterRadius = 0.02
        let mean = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        settings.filterMode = .bilateral
        let bilateral = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        XCTAssertLessThan(bilateral.vertices[1].position.z, mean.vertices[1].position.z * 0.2)
        XCTAssertGreaterThan(bilateral.vertices[2].position.z, 0.005)
    }

    func testFilterRadiusAndPassCountAffectLocalNoise() {
        let input = (-3...3).map { x in point(Float(x) * 0.001, 0, x == 0 ? 0.0002 : 0) }
        var settings = baseSettings()
        settings.filterEnabled = true
        settings.filterStrength = 1
        settings.filterRadius = 0.0003
        let isolated = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        XCTAssertEqual(isolated.vertices[3].position.z, 0.0002, accuracy: 0.000001)
        settings.filterRadius = 0.0015
        let once = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        settings.filterPasses = 3
        let repeated = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        XCTAssertLessThan(once.vertices[3].position.z, isolated.vertices[3].position.z)
        XCTAssertLessThan(repeated.vertices[3].position.z, once.vertices[3].position.z)
    }

    func testOutlierRemovalKeepsClusterAndItsOriginalIndices() {
        let input = [point(0, 0, 0), point(0.001, 0, 0), point(0, 0.001, 0), point(0.1, 0.1, 0.1)]
        var settings = baseSettings()
        settings.outlierRemovalEnabled = true
        settings.outlierMinNeighbors = 2
        settings.filterRadius = 0.005
        let output = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        XCTAssertEqual(output.sourceIndices, [0, 1, 2])
        XCTAssertEqual(output.vertices.count, 3)
    }

    func testSourceFacesRemapAndRejectInvalidDegenerateAndLongEdges() {
        let input = [point(.nan, 0, 0), point(0, 0, 0), point(0.004, 0, 0),
                     point(0, 0.004, 0), point(0.1, 0, 0)]
        var settings = baseSettings()
        settings.meshEnabled = true
        settings.meshEdgeLimit = 0.01
        let faces: [UInt32] = [1, 2, 3, 0, 2, 3, 1, 1, 3, 1, 2, 99, 1, 2, 4, 1]
        let output = ScanLabGeometryProcessor.process(vertices: input, triangleIndices: faces, settings: settings)
        XCTAssertEqual(output.sourceIndices, [1, 2, 3, 4])
        XCTAssertEqual(output.triangleIndices, [0, 1, 2])
        XCTAssertEqual(output.normals[0].z, 1, accuracy: 0.00001)
        XCTAssertTrue(output.normals.allSatisfy { abs(simd_length($0) - 1) < 0.0001 })
    }

    func testMeshStrideKeepsEveryValidMeasuredFace() {
        let input = [point(0, 0, 0), point(0.004, 0, 0),
                     point(0, 0.004, 0), point(0.004, 0.004, 0)]
        let sourceFaces: [UInt32] = [0, 1, 2, 1, 3, 2]
        for meshStride in [1, 2, 4, 8] {
            var settings = baseSettings()
            settings.displayMode = .surface
            settings.meshStride = meshStride
            let output = ScanLabGeometryProcessor.process(vertices: input,
                                                           triangleIndices: sourceFaces, settings: settings)
            XCTAssertEqual(output.triangleIndices, sourceFaces,
                           "Measured surfaces must not gain artificial gaps when preview stride changes.")
        }
    }

    func testMeshStrideStillChangesProjectedAdjacencyResolution() {
        let input = grid(size: 30, spacing: 0.001)
        var settings = baseSettings()
        settings.displayMode = .surface
        settings.meshEdgeLimit = 0.02
        let fine = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        settings.meshStride = 4
        let coarse = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        XCTAssertFalse(coarse.triangleIndices.isEmpty)
        XCTAssertLessThan(coarse.triangleIndices.count, fine.triangleIndices.count)
        XCTAssertEqual(coarse.vertices.count, fine.vertices.count)
        assertEdges(coarse, maximum: 0.02)
    }

    func testCancelledJobsReturnConsistentEmptyResultsForEveryPreviewConfiguration() async {
        let input = grid(size: 20, spacing: 0.001)
        for configuration in 0..<4 {
            var settings = baseSettings()
            settings.outlierRemovalEnabled = configuration == 1
            settings.filterEnabled = configuration == 2
            settings.meshEnabled = configuration == 3
            let configuredSettings = settings
            let task = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return ScanLabGeometryProcessor.process(vertices: input, settings: configuredSettings)
            }
            let output = await task.value
            XCTAssertTrue(output.vertices.isEmpty)
            XCTAssertTrue(output.triangleIndices.isEmpty)
            XCTAssertTrue(output.normals.isEmpty)
            XCTAssertTrue(output.sourceIndices.isEmpty)
            XCTAssertEqual(output.originalPointCount, input.count)
        }
    }

    func testDensityRemappingNeverConnectsWrongSourceVertices() {
        let input = [point(0, 0, 0), point(0.1, 0, 0), point(0.004, 0, 0),
                     point(0.2, 0, 0), point(0.3, 0, 0), point(0, 0.004, 0)]
        var settings = baseSettings()
        settings.pointDensity = 0.5
        settings.displayMode = .surface
        let output = ScanLabGeometryProcessor.process(vertices: input,
                                                       triangleIndices: [0, 2, 5, 0, 1, 2], settings: settings)
        XCTAssertEqual(output.sourceIndices, [0, 2, 5])
        XCTAssertEqual(output.triangleIndices, [0, 1, 2])
    }

    func testProjectionBuildsLocalDisplayFacesWithFiniteFrontFacingNormals() {
        let input = grid(size: 12, spacing: 0.002)
        var settings = baseSettings()
        settings.displayMode = .wireframe
        settings.meshEdgeLimit = 0.008
        let output = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        XCTAssertFalse(output.triangleIndices.isEmpty)
        XCTAssertEqual(output.vertices.count, input.count, "A display mesh must not synthesize acquired points.")
        assertEdges(output, maximum: 0.008)
        for offset in stride(from: 0, to: output.triangleIndices.count, by: 3) {
            let a = output.vertices[Int(output.triangleIndices[offset])].position
            let b = output.vertices[Int(output.triangleIndices[offset + 1])].position
            let c = output.vertices[Int(output.triangleIndices[offset + 2])].position
            XCTAssertGreaterThan(simd_cross(b - a, c - a).z, 0)
        }
    }

    func testProjectionDoesNotBridgeDepthDiscontinuityOrEmptyBand() {
        let input = grid(size: 15, spacing: 0.002).filter { abs($0.position.x - 0.014) > 0.0021 }.map {
            var vertex = $0
            vertex.position.z = vertex.position.x > 0.014 ? 0.018 : 0
            return vertex
        }
        var settings = baseSettings()
        settings.displayMode = .surface
        settings.meshEdgeLimit = 0.01
        let output = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        XCTAssertFalse(output.triangleIndices.isEmpty)
        assertEdges(output, maximum: 0.01)
        for offset in stride(from: 0, to: output.triangleIndices.count, by: 3) {
            let triangle = (0..<3).map { output.vertices[Int(output.triangleIndices[offset + $0])].position }
            XCTAssertEqual(triangle.map(\.z).min(), triangle.map(\.z).max())
            let xs = triangle.map(\.x)
            XCTAssertTrue(xs.allSatisfy { $0 < 0.012 } || xs.allSatisfy { $0 > 0.016 })
        }
    }

    func testDenseSingleCellAndExtremeFinitePositionsRemainBoundedAndFinite() {
        var input = Array(repeating: point(0, 0, 0), count: 30_000)
        input.append(point(.greatestFiniteMagnitude, 0, 0))
        var settings = baseSettings()
        settings.filterEnabled = true
        settings.filterMode = .bilateral
        settings.filterRadius = .nan
        settings.filterStrength = .infinity
        settings.pointDensity = .nan
        let output = ScanLabGeometryProcessor.process(vertices: input, settings: settings)
        XCTAssertEqual(output.vertices.count, 24_000)
        XCTAssertEqual(output.sourceIndices.last, 30_000)
        XCTAssertTrue(output.vertices.allSatisfy {
            $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite
        })
    }

    private func baseSettings() -> ScanLabSettings {
        var settings = ScanLabSettings()
        settings.pointDensity = 1
        settings.meshStride = 1
        return settings
    }

    private func point(_ x: Float, _ y: Float, _ z: Float) -> ScanVertex {
        ScanVertex(position: SIMD3(x, y, z), color: SIMD3(0.3, 0.5, 0.7))
    }

    private func grid(size: Int, spacing: Float) -> [ScanVertex] {
        (0..<(size * size)).map { index in
            point(Float(index % size) * spacing, Float(index / size) * spacing, 0)
        }
    }

    private func assertEdges(_ geometry: ScanLabProcessedGeometry, maximum: Float,
                             file: StaticString = #filePath, line: UInt = #line) {
        for offset in stride(from: 0, to: geometry.triangleIndices.count, by: 3) {
            let points = (0..<3).map { geometry.vertices[Int(geometry.triangleIndices[offset + $0])].position }
            XCTAssertLessThanOrEqual(simd_distance(points[0], points[1]), maximum, file: file, line: line)
            XCTAssertLessThanOrEqual(simd_distance(points[1], points[2]), maximum, file: file, line: line)
            XCTAssertLessThanOrEqual(simd_distance(points[2], points[0]), maximum, file: file, line: line)
        }
    }
}

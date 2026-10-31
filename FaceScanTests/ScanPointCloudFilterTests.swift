import Foundation
import XCTest
@testable import FaceScan

final class ScanPointCloudFilterTests: XCTestCase {
    func testAdapterMatchesSuppliedReferenceAndPreservesOriginalScan() throws {
        let source = fixture()
        let originalPositions = source.vertices.map(\.position)
        let originalColors = source.vertices.map(\.color)
        let expected = try FacePointCloudProcessor.process(source.vertices.map {
            FaceCloudPoint(position: $0.position, color: SIMD3(byte($0.color.x), byte($0.color.y), byte($0.color.z)))
        })
        let filtered = try ScanPointCloudFilter.process(source)

        XCTAssertEqual(filtered.mesh.vertexCount, expected.points.count)
        XCTAssertEqual(filtered.statistics.inputCount, source.vertexCount)
        XCTAssertEqual(filtered.statistics.outputCount, filtered.mesh.vertexCount)
        XCTAssertEqual(filtered.statistics.sorRejectedCount, expected.statistics.sorRejectedCount)
        XCTAssertEqual(filtered.statistics.modelRejectedCount, expected.statistics.modelRejectedCount)
        XCTAssertGreaterThan(filtered.statistics.sorRejectedCount, 0, "The isolated fixture points should be rejected.")
        XCTAssertEqual(filtered.mesh.frameCount, source.frameCount)
        XCTAssertEqual(filtered.mesh.coveredAngles, source.coveredAngles)
        XCTAssertEqual(filtered.mesh.isSample, source.isSample)
        XCTAssertTrue(filtered.mesh.isFiltered)
        XCTAssertTrue(filtered.mesh.triangleIndices.isEmpty, "Filtering invalidates measured faces.")
        XCTAssertNotEqual(filtered.mesh.renderIdentity, source.renderIdentity)
        for (vertex, expectedPoint) in zip(filtered.mesh.vertices, expected.points) {
            XCTAssertEqual(vertex.position, expectedPoint.position)
            XCTAssertEqual(vertex.color, SIMD3(Float(expectedPoint.color.x), Float(expectedPoint.color.y),
                                               Float(expectedPoint.color.z)) / 255)
        }
        XCTAssertEqual(source.vertices.map(\.position), originalPositions)
        XCTAssertEqual(source.vertices.map(\.color), originalColors)
        XCTAssertEqual(source.triangleIndices, [0, 1, 2])
        XCTAssertFalse(source.isFiltered)
    }

    func testColorConversionClampsAndRoundsTiesToEven() throws {
        var source = fixture()
        source.vertices = source.vertices.map {
            ScanVertex(position: $0.position, color: SIMD3(-0.25, 0.5, 1.25))
        }
        let filtered = try ScanPointCloudFilter.process(source)
        for vertex in filtered.mesh.vertices {
            XCTAssertEqual(vertex.color, SIMD3(0, Float(128) / 255, 1))
        }
    }

    func testEmptyTooSmallAndNonfiniteInputsThrowUsefulErrors() throws {
        let empty = ScanMesh(vertices: [], triangleIndices: [], frameCount: 0, coveredAngles: [])
        XCTAssertThrowsError(try ScanPointCloudFilter.process(empty)) { error in
            XCTAssertTrue(error is ScanPointCloudFilter.FilterError)
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        var source = fixture()
        source.vertices = Array(source.vertices.prefix(20))
        XCTAssertThrowsError(try ScanPointCloudFilter.process(source)) { error in
            guard case FaceCloudProcessingError.tooFewPoints(required: 21, actual: 20) = error else {
                return XCTFail("Expected the supplied SOR neighbor requirement, got \(error)")
            }
        }
        source = fixture()
        source.vertices[1].position.x = .nan
        XCTAssertThrowsError(try ScanPointCloudFilter.process(source)) { error in
            guard case ScanPointCloudFilter.FilterError.invalidVertex(1) = error else {
                return XCTFail("Expected a localized invalid-vertex error, got \(error)")
            }
        }
        source = fixture()
        source.vertices[2].color.z = .infinity
        XCTAssertThrowsError(try ScanPointCloudFilter.process(source)) { error in
            guard case ScanPointCloudFilter.FilterError.invalidVertex(2) = error else {
                return XCTFail("Expected color validation before integer conversion, got \(error)")
            }
        }
    }

    func testAsyncMatchesSynchronousOutput() async throws {
        let source = fixture()
        let expected = try ScanPointCloudFilter.process(source)
        let actual = try await ScanPointCloudFilter.processAsync(source)
        XCTAssertEqual(actual.mesh.vertices.map(\.position), expected.mesh.vertices.map(\.position))
        XCTAssertEqual(actual.mesh.vertices.map(\.color), expected.mesh.vertices.map(\.color))
        XCTAssertEqual(actual.statistics.outputCount, expected.statistics.outputCount)
    }

    func testCustomSettingsReachReferenceProcessorAndChangeTheOutput() async throws {
        var source = fixture()
        for index in source.vertices.indices {
            source.vertices[index].color = SIMD3(Float(index % 13) / 12, Float(index % 7) / 6, 0.5)
        }
        var settings = ScanFilterSettings.gentle
        settings.bilateralIterations = 0
        settings.parameterGridSize = 0.0006
        settings.maximumRadialDisplacement = 0.02
        let input = source.vertices.map {
            FaceCloudPoint(position: $0.position, color: SIMD3(byte($0.color.x), byte($0.color.y), byte($0.color.z)))
        }
        let expected = try FacePointCloudProcessor.process(input, configuration: settings.configuration)
        let actual = try await ScanPointCloudFilter.processAsync(source, settings: settings)
        let reference = try ScanPointCloudFilter.process(source)

        XCTAssertEqual(actual.settings, settings)
        XCTAssertEqual(actual.mesh.filterSettings, settings)
        XCTAssertEqual(actual.mesh.vertices.map(\.position), expected.points.map(\.position))
        XCTAssertEqual(actual.mesh.vertices.map(\.color), expected.points.map {
            SIMD3(Float($0.color.x), Float($0.color.y), Float($0.color.z)) / 255
        })
        XCTAssertNotEqual(actual.mesh.vertices.map(\.position), reference.mesh.vertices.map(\.position),
                          "Changing smoothing/grid parameters must change the processed geometry.")
        for (vertex, sourceIndex) in zip(actual.mesh.vertices, expected.sourceIndices) {
            let originalColor = input[sourceIndex].color
            XCTAssertEqual(vertex.color, SIMD3(Float(originalColor.x), Float(originalColor.y), Float(originalColor.z)) / 255,
                           "Disabling color filtering preserves each surviving point's input RGB.")
        }
    }

    func testCancellationDoesNotReturnAFilteredScan() async throws {
        let source = fixture()
        let task = Task.detached { try await ScanPointCloudFilter.processAsync(source) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled filter must not return a result for presentation.")
        } catch is CancellationError {
            // Expected: cancellation is forwarded to the processing task.
        }
        let synchronous = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ScanPointCloudFilter.process(source)
        }
        do {
            _ = try await synchronous.value
            XCTFail("Synchronous conversion must also honor cancellation.")
        } catch is CancellationError {}
    }

    func testProgressTracksCompletedStagesWithoutChangingTheFilteredOutput() throws {
        let source = fixture()
        var settings = ScanFilterSettings.gentle
        settings.medianWindow = 3
        settings.smoothingCurve = .featurePreserving
        let expected = try ScanPointCloudFilter.process(source, settings: settings)
        let observed = FilterProgressSamples()
        let actual = try ScanPointCloudFilter.process(source, settings: settings,
                                                     onProgress: { observed.append($0) })

        let values = observed.values
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertTrue(values.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertGreaterThan(values.filter { $0 > 0.03 && $0 < 0.96 }.count, 4,
                             "SOR, grid, adaptive, median and interpolation work must report intermediate completion.")
        XCTAssertEqual(actual.mesh.vertices.map(\.position), expected.mesh.vertices.map(\.position))
        XCTAssertEqual(actual.mesh.vertices.map(\.color), expected.mesh.vertices.map(\.color))
        XCTAssertEqual(actual.statistics.outputCount, expected.statistics.outputCount)
    }

    func testCancellationDuringReportedWorkNeverReportsCompletion() throws {
        let input = fixture().vertices.map {
            FaceCloudPoint(position: $0.position,
                           color: SIMD3(byte($0.color.x), byte($0.color.y), byte($0.color.z)))
        }
        let observed = FilterProgressSamples(cancelAt: 0.2)
        XCTAssertThrowsError(try FacePointCloudProcessor.process(input,
            onProgress: { observed.append($0) }, isCancelled: { observed.isCancelled })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(observed.values.contains { $0 >= 0.2 })
        XCTAssertFalse(observed.values.contains(1), "Cancelled work must not claim successful completion.")
    }

    private func fixture() -> ScanMesh {
        var vertices: [ScanVertex] = []
        for row in 0..<23 {
            for column in 0..<37 {
                let theta = -0.8 + Double(column) * 1.6 / 36
                let radius = 0.10 + 0.001 * sin(Double(row * 11 + column * 7))
                let position = SIMD3(Float(radius * sin(theta)), Float(row - 11) * 0.004,
                                     Float(-0.05 + radius * cos(theta)))
                vertices.append(ScanVertex(position: position, color: SIMD3(0.3, 0.5, 0.7)))
            }
        }
        for offset in 0..<3 {
            vertices.append(ScanVertex(position: SIMD3(0.4 + Float(offset) * 0.1, 0.3, 0.4),
                                       color: SIMD3(1, 0, 0)))
        }
        return ScanMesh(vertices: vertices, triangleIndices: [0, 1, 2], frameCount: 42,
                        coveredAngles: [.center, .left, .chin], isSample: true)
    }

    private func byte(_ value: Float) -> UInt8 {
        UInt8((min(max(value, 0), 1) * 255).rounded(.toNearestOrEven))
    }
}

/// Progress may be delivered from a detached worker; sample access is locked.
private final class FilterProgressSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    private let cancelAt: Double?
    private var cancelled = false

    init(cancelAt: Double? = nil) { self.cancelAt = cancelAt }

    func append(_ value: Double) {
        lock.lock()
        samples.append(value)
        if let cancelAt, value >= cancelAt { cancelled = true }
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

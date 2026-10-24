import Foundation
import simd
import XCTest
@testable import FaceScan

final class ScanSurfaceBuilderTests: XCTestCase {
    func testConfirmedPointCloudFormsResultWithoutAnyTriangles() throws {
        let points = confirmedPoints(count: ScanSurfaceBuilder.minimumPointCount)
        let mesh = try XCTUnwrap(ScanSurfaceBuilder.makeMesh(
            accumulators: points, triangles: [], frameCount: 2, coveredAngles: []))

        XCTAssertEqual(mesh.vertexCount, points.count)
        XCTAssertTrue(mesh.triangleIndices.isEmpty)
        XCTAssertEqual(mesh.frameCount, 2)
        XCTAssertTrue(mesh.coveredAngles.isEmpty)
        XCTAssertFalse(mesh.isSample)
    }

    func testManyPixelsInSingleFrameCannotFormConfirmedResult() {
        var point = PointFusionAccumulator(position: .zero, color: .zero, frameNumber: 1)
        for _ in 0..<1_000 {
            point.add(position: .zero, color: .zero, frameNumber: 1)
        }
        let points = Array(repeating: point, count: ScanSurfaceBuilder.minimumPointCount)
        XCTAssertNil(ScanSurfaceBuilder.makeMesh(
            accumulators: points, triangles: [], frameCount: 2, coveredAngles: [.center]))
        XCTAssertNil(ScanSurfaceBuilder.makeMesh(
            accumulators: confirmedPoints(count: ScanSurfaceBuilder.minimumPointCount - 1),
            triangles: [], frameCount: 2, coveredAngles: [.center]))
    }

    func testCoverageCountsDistinctConfirmedPointsWithoutRequiringTriangles() {
        var points = confirmedPoints(count: 250)
        points.append(PointFusionAccumulator(position: .zero, color: .zero, frameNumber: 2))
        let pixels = Array(0..<250) + Array(repeating: 249, count: 100)
            + [250, -1, 999]

        XCTAssertEqual(ScanSurfaceBuilder.confirmedPointCount(in: pixels, accumulators: points), 250)
        XCTAssertEqual(ScanSurfaceBuilder.confirmedPointCount(in: [-1, 250], accumulators: points), 0)
    }

    func testLatestReplacementDropsStretchedTriangleButPreservesExportablePoints() throws {
        var points = confirmedPoints(count: ScanSurfaceBuilder.minimumPointCount)
        points[0] = confirmedPoint(SIMD3(0, 0, 0))
        points[1] = confirmedPoint(SIMD3(0.005, 0, 0))
        points[2] = confirmedPoint(SIMD3(0, 0.005, 0))
        let triangles = [ScanTriangle(a: 0, b: 1, c: 2)]
        let original = try XCTUnwrap(ScanSurfaceBuilder.makeMesh(
            accumulators: points, triangles: triangles, frameCount: 2, coveredAngles: [.center]))
        XCTAssertEqual(original.triangleIndices, [0, 1, 2])

        let newestPosition = SIMD3<Float>(0.03, 0, 0)
        points[1].add(position: newestPosition, color: SIMD3(0, 0, 1), frameNumber: 3)
        let updated = try XCTUnwrap(ScanSurfaceBuilder.makeMesh(
            accumulators: points, triangles: triangles, frameCount: 3, coveredAngles: [.center]))
        XCTAssertEqual(updated.vertices[1].position, newestPosition)
        XCTAssertEqual(updated.vertices[1].color, SIMD3(0, 0, 1))
        XCTAssertTrue(updated.triangleIndices.isEmpty)

        let url = try ScanExporter.export(updated)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try String(contentsOf: url, encoding: .utf8)
        let body = try XCTUnwrap(file.components(separatedBy: "end_header\n").last)
        let lines = body.split(separator: "\n")
        XCTAssertEqual(lines.count, points.count)
        XCTAssertEqual(lines[1], "0.03 0.0 0.0 0 0 255")
        XCTAssertTrue(file.contains("element face 0\n"))
        XCTAssertTrue(file.contains("comment accepted_depth_frames 3\n"))
    }

    func testUnconfirmedPointsAreRemovedAndValidTrianglesAreRemapped() throws {
        var points = confirmedPoints(count: ScanSurfaceBuilder.minimumPointCount)
        points[0] = confirmedPoint(SIMD3(0, 0, 0))
        points[1] = confirmedPoint(SIMD3(0.005, 0, 0))
        points[2] = confirmedPoint(SIMD3(0, 0.005, 0))
        points.insert(PointFusionAccumulator(position: .zero, color: .zero, frameNumber: 2), at: 1)
        let mesh = try XCTUnwrap(ScanSurfaceBuilder.makeMesh(
            accumulators: points,
            triangles: [ScanTriangle(a: 0, b: 2, c: 3), ScanTriangle(a: 0, b: 1, c: 2),
                        ScanTriangle(a: -1, b: 2, c: 3), ScanTriangle(a: 0, b: 2, c: 999)],
            frameCount: 2, coveredAngles: [.center]))

        XCTAssertEqual(mesh.vertexCount, ScanSurfaceBuilder.minimumPointCount)
        XCTAssertEqual(mesh.triangleIndices, [0, 1, 2])
    }

    private func confirmedPoints(count: Int) -> [PointFusionAccumulator] {
        (0..<count).map { index in
            confirmedPoint(SIMD3(Float(index % 15) * 0.002,
                                 Float(index / 15) * 0.002, 0))
        }
    }

    private func confirmedPoint(_ position: SIMD3<Float>) -> PointFusionAccumulator {
        var point = PointFusionAccumulator(position: position,
                                           color: SIMD3(1, 0, 0), frameNumber: 1)
        point.add(position: position, color: SIMD3(1, 0, 0), frameNumber: 2)
        return point
    }
}

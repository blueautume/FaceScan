import QuartzCore
import SceneKit
import XCTest
@testable import FaceScan

final class PointCloudRenderPerformanceTests: XCTestCase {
    /// A CPU microbenchmark, not a device frame-rate or end-to-end latency measurement.
    /// The optimized timing intentionally excludes preparation, which runs off the UI actor.
    @MainActor
    func testPreparedDisplayInstallationCostAtPreviewAndFullResultSizes() throws {
        for pointCount in [24_000, 180_000] {
            let mesh = fixture(pointCount: pointCount)
            let builder = PointCloudRenderDataBuilder()
            let prepared = builder.prepare(
                vertices: mesh.vertices, triangleIndices: mesh.triangleIndices)
            let resources = PointCloudRenderResources()
            try autoreleasepool {
                let baseline = try XCTUnwrap(LivePointGeometryBuilder.makeSurfaceGeometry(mesh: mesh))
                let optimized = resources.make(data: prepared)
                let points = try XCTUnwrap(optimized.points)
                let surface = try XCTUnwrap(optimized.surface)
                XCTAssertEqual(points.sources(for: .vertex).first?.vectorCount, pointCount)
                XCTAssertEqual(surface.sources(for: .vertex).first?.vectorCount, pointCount)
                XCTAssertEqual(baseline.sources(for: .vertex).first?.vectorCount, pointCount)
                XCTAssertEqual(points.elements.first?.primitiveCount, pointCount)
                XCTAssertEqual(surface.elements.first?.primitiveCount, mesh.triangleIndices.count / 3)
                XCTAssertEqual(baseline.elements.first?.primitiveCount, surface.elements.first?.primitiveCount)
                XCTAssertEqual(baseline.elements.first?.data, surface.elements.first?.data)
                for semantic: SCNGeometrySource.Semantic in [.vertex, .color] {
                    let originalSource = try XCTUnwrap(baseline.sources(for: semantic).first)
                    let preparedSource = try XCTUnwrap(surface.sources(for: semantic).first)
                    XCTAssertEqual(originalSource.data, preparedSource.data)
                    XCTAssertEqual(originalSource.dataOffset, preparedSource.dataOffset)
                    XCTAssertEqual(originalSource.dataStride, preparedSource.dataStride)
                }
            }

            // Both paths have already run once; keep resources warm as they are
            // during a scan and drain temporary SceneKit objects after each sample.
            var baselineTimes: [Double] = []
            var preparationTimes: [Double] = []
            var installationTimes: [Double] = []
            for _ in 0..<3 {
                baselineTimes.append(milliseconds {
                    LivePointGeometryBuilder.makeSurfaceGeometry(mesh: mesh)
                })
                let start = CACurrentMediaTime()
                let next = builder.prepare(vertices: mesh.vertices, triangleIndices: mesh.triangleIndices)
                preparationTimes.append((CACurrentMediaTime() - start) * 1_000)
                installationTimes.append(milliseconds {
                    resources.make(data: next).surface
                })
            }
            let baselineMedian = baselineTimes.sorted()[1]
            let preparationMedian = preparationTimes.sorted()[1]
            let installationMedian = installationTimes.sorted()[1]
            let report = String(
                format: "PERF_RENDER points=%d triangles=%d baseline_full_cpu_ms=%.3f worker_prepare_cpu_ms=%.3f prepared_install_cpu_ms=%.3f samples=3 scope=CPU_construction_only_excludes_GPU_and_FPS",
                pointCount, mesh.triangleIndices.count / 3,
                baselineMedian, preparationMedian, installationMedian)
            print(report)
            let attachment = XCTAttachment(string: report)
            attachment.name = "Render CPU construction — \(pointCount) points"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func milliseconds(_ build: () -> SCNGeometry?) -> Double {
        autoreleasepool {
            let start = CACurrentMediaTime()
            let geometry = build()
            let elapsed = (CACurrentMediaTime() - start) * 1_000
            XCTAssertNotNil(geometry)
            return elapsed
        }
    }

    private func fixture(pointCount: Int) -> ScanMesh {
        var vertices: [ScanVertex] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(pointCount)
        indices.reserveCapacity(pointCount)
        for triangle in 0..<(pointCount / 3) {
            let x = Float(triangle % 300) * 0.0005 - 0.075
            let y = Float(triangle / 300) * 0.0005 - 0.05
            let z = Float(triangle % 11) * 0.0002
            let color = SIMD3<Float>(Float(triangle % 17) / 16,
                                     Float(triangle % 13) / 12,
                                     Float(triangle % 7) / 6)
            let first = UInt32(vertices.count)
            vertices.append(ScanVertex(position: SIMD3(x, y, z), color: color))
            vertices.append(ScanVertex(position: SIMD3(x + 0.001, y, z), color: color))
            vertices.append(ScanVertex(position: SIMD3(x, y + 0.001, z), color: color))
            indices.append(first)
            indices.append(first + 1)
            indices.append(first + 2)
        }
        return ScanMesh(vertices: vertices, triangleIndices: indices,
                        frameCount: 20, coveredAngles: [.center])
    }
}

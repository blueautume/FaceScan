import XCTest
import simd
@testable import FaceScan

final class ScanLabDemoTests: XCTestCase {
    func testDemoIsDeterministicAndNoiseDoesNotChangeColorOrSource() {
        let source = SampleFaceMesh.make().vertices
        let clean = ScanLabDemo.vertices(noise: 0)
        let noisy = ScanLabDemo.vertices(noise: 0.003)
        let repeated = ScanLabDemo.vertices(noise: 0.003)
        XCTAssertEqual(noisy.count, source.count)
        XCTAssertEqual(noisy.map(\.position), repeated.map(\.position))
        XCTAssertEqual(noisy.map(\.color), repeated.map(\.color))
        XCTAssertNotEqual(clean.map(\.position), noisy.map(\.position))
        XCTAssertEqual(Set(clean.map { PositionKey($0.position) }),
                       Set(source.map { PositionKey($0.position) }))
        XCTAssertEqual(source.map(\.position), SampleFaceMesh.make().vertices.map(\.position))
    }

    func testInvalidNoiseUsesCleanFixture() {
        let clean = ScanLabDemo.vertices(noise: 0).map(\.position)
        XCTAssertEqual(ScanLabDemo.vertices(noise: .nan).map(\.position), clean)
        XCTAssertEqual(ScanLabDemo.vertices(noise: -1).map(\.position), clean)
    }

    func testSortedDemoPreservesTheKnownSyntheticSurface() {
        let original = SampleFaceMesh.make()
        let sorted = ScanLabDemo.mesh(noise: 0)
        XCTAssertEqual(sorted.triangleIndices.count, original.triangleIndices.count)
        for index in original.triangleIndices.indices {
            XCTAssertEqual(sorted.vertices[Int(sorted.triangleIndices[index])].position,
                           original.vertices[Int(original.triangleIndices[index])].position)
        }
    }

    private struct PositionKey: Hashable {
        let x: Float
        let y: Float
        let z: Float
        init(_ value: SIMD3<Float>) { x = value.x; y = value.y; z = value.z }
    }
}

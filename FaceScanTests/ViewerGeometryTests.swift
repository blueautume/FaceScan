import XCTest
import simd
@testable import FaceScan

final class ViewerGeometryTests: XCTestCase {
    func testPreviewCannotBeMistakenForAnAcquiredScan() {
        let mesh = SampleFaceMesh.make()
        XCTAssertTrue(mesh.isSample, "Synthetic preview geometry must never be labeled as a real scan.")
        XCTAssertEqual(mesh.frameCount, 0)
        XCTAssertTrue(mesh.coveredAngles.isEmpty)
    }

    func testSurfaceHasFiniteNondegenerateOutwardTriangles() throws {
        let mesh = SampleFaceMesh.make()
        XCTAssertFalse(mesh.vertices.isEmpty)
        XCTAssertFalse(mesh.triangleIndices.isEmpty)
        XCTAssertEqual(mesh.triangleIndices.count % 3, 0)
        XCTAssertTrue(mesh.vertices.allSatisfy {
            $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite
        })
        let invalidIndex = mesh.triangleIndices.first { Int($0) >= mesh.vertices.count }
        XCTAssertNil(invalidIndex)
        guard invalidIndex == nil else { return }

        var leastAreaSquared = Float.infinity
        var backwardTriangles = 0
        for offset in stride(from: 0, to: mesh.triangleIndices.count, by: 3) {
            let a = mesh.vertices[Int(mesh.triangleIndices[offset])].position
            let b = mesh.vertices[Int(mesh.triangleIndices[offset + 1])].position
            let c = mesh.vertices[Int(mesh.triangleIndices[offset + 2])].position
            let normal = simd_cross(b - a, c - a)
            leastAreaSquared = min(leastAreaSquared, simd_length_squared(normal))
            if normal.z <= 0 { backwardTriangles += 1 }
        }
        XCTAssertGreaterThan(leastAreaSquared, 1e-16, "Collapsed triangles cause unstable shading.")
        XCTAssertEqual(backwardTriangles, 0, "The viewer camera is at +Z, so the facial surface must face +Z.")
    }

    func testNoseProjectsBeyondCheeksAndEyesAreRecessed() throws {
        let mesh = SampleFaceMesh.make()
        let nose = try closestPoint(in: mesh, to: SIMD2(0, 0.004))
        let leftCheek = try closestPoint(in: mesh, to: SIMD2(-0.035, 0.004))
        let rightCheek = try closestPoint(in: mesh, to: SIMD2(0.035, 0.004))
        XCTAssertGreaterThan(nose.z - max(leftCheek.z, rightCheek.z), 0.015,
                             "The demonstration must have measurable nose depth, not a flat portrait plane.")

        for side: Float in [-1, 1] {
            let eye = try closestPoint(in: mesh, to: SIMD2(side * 0.031, 0.030))
            let brow = try closestPoint(in: mesh, to: SIMD2(side * 0.031, 0.049))
            XCTAssertGreaterThan(brow.z - eye.z, 0.003, "Eye sockets should be recessed behind the brow.")
        }
    }

    func testSurfaceUsesFaceScaleAndNonconstantValidRGB() throws {
        let mesh = SampleFaceMesh.make()
        var low = try XCTUnwrap(mesh.vertices.first).position
        var high = low
        var darkest = Float.infinity
        var lightest = -Float.infinity
        for vertex in mesh.vertices {
            low = simd_min(low, vertex.position)
            high = simd_max(high, vertex.position)
            for component in [vertex.color.x, vertex.color.y, vertex.color.z] {
                XCTAssertTrue(component.isFinite)
                XCTAssertGreaterThanOrEqual(component, 0)
                XCTAssertLessThanOrEqual(component, 1)
                darkest = min(darkest, component)
                lightest = max(lightest, component)
            }
        }
        let size = high - low
        XCTAssertTrue((0.10...0.22).contains(size.x), "Mesh units must be meters rather than pixels.")
        XCTAssertTrue((0.17...0.30).contains(size.y))
        XCTAssertTrue((0.025...0.13).contains(size.z))
        XCTAssertGreaterThan(lightest - darkest, 0.25, "Original-color preview should contain facial color variation.")
    }

    private func closestPoint(in mesh: ScanMesh, to location: SIMD2<Float>) throws -> SIMD3<Float> {
        try XCTUnwrap(mesh.vertices.min {
            simd_length_squared(SIMD2($0.position.x, $0.position.y) - location)
                < simd_length_squared(SIMD2($1.position.x, $1.position.y) - location)
        }).position
    }
}

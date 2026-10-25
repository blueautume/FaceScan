import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import FaceScan

final class ScanHistoryThumbnailRendererTests: XCTestCase {
    func testActualPointsProduceACompleteAngledPreviewWithoutChangingSource() throws {
        let source = mesh([
            vertex(-0.03, 0.02, 0, color: SIMD3(1, 0, 0)),
            vertex(0.03, -0.02, 0, color: SIMD3(0, 0, 1)),
            vertex(0, 0, 0.06, color: SIMD3(0, 1, 0)),
            vertex(0, 0.08, 0, color: SIMD3(repeating: 0.7)),
            vertex(0, -0.08, 0, color: SIMD3(repeating: 0.7))
        ])
        let originalPositions = source.vertices.map(\.position)
        let originalColors = source.vertices.map(\.color)
        let data = try ScanHistoryThumbnailRenderer.render(source)
        XCTAssertTrue(ScanHistoryThumbnailRenderer.isValidCache(data))
        let picture = try pixels(data)
        XCTAssertEqual(picture.width, 256)
        XCTAssertEqual(picture.height, 256)
        let red = try XCTUnwrap(picture.centroid { $0.0 > 150 && $0.1 < 80 && $0.2 < 80 })
        let blue = try XCTUnwrap(picture.centroid { $0.2 > 150 && $0.0 < 80 && $0.1 < 80 })
        let green = try XCTUnwrap(picture.centroid { $0.1 > 150 && $0.0 < 80 && $0.2 < 80 })
        XCTAssertLessThan(red.y, blue.y, "+Y in the scan must remain upward in the image.")
        XCTAssertLessThan(green.x, (red.x + blue.x) * 0.5 - 10,
                          "A forward point must shift sideways in the fixed yaw view, rather than showing a frontal icon.")
        let painted = picture.nonBackgroundCoordinates
        XCTAssertGreaterThan(painted.count, 8)
        XCTAssertTrue(painted.allSatisfy { $0.x >= 12 && $0.x <= 244 && $0.y >= 12 && $0.y <= 244 },
                      "Rotated model bounds need padding on all sides.")
        XCTAssertEqual(source.vertices.map(\.position), originalPositions)
        XCTAssertEqual(source.vertices.map(\.color), originalColors)
        XCTAssertEqual(try ScanHistoryThumbnailRenderer.render(source), data,
                       "A history preview must stay deterministic for its immutable original.")
    }

    func testNearPointOccludesFarPointRegardlessOfInputOrder() throws {
        let yaw = -25.0 * Double.pi / 180, pitch = -10.0 * Double.pi / 180
        let distance = 0.02
        // Inverse rotation of a camera-axis point: the two source positions
        // project onto one pixel but have different actual depth.
        let front = SIMD3<Float>(Float(-sin(yaw) * cos(pitch) * distance),
                                 Float(sin(pitch) * distance), Float(cos(yaw) * cos(pitch) * distance))
        let near = ScanVertex(position: front, color: SIMD3(0, 0, 1))
        let far = ScanVertex(position: -front, color: SIMD3(1, 0, 0))
        for points in [[near, far], [far, near]] {
            let picture = try pixels(ScanHistoryThumbnailRenderer.render(mesh(points)))
            XCTAssertNotNil(picture.centroid { $0.2 > 150 && $0.0 < 80 && $0.1 < 80 })
            XCTAssertNil(picture.centroid { $0.0 > 150 && $0.1 < 80 && $0.2 < 80 },
                         "Rear points must not cover the visible front of the cloud.")
        }
    }

    func testMissingInvalidAndWrongSizedCacheAreRejected() throws {
        let data = try ScanHistoryThumbnailRenderer.render(mesh([vertex(0, 0, 0)]))
        XCTAssertTrue(ScanHistoryThumbnailRenderer.isValidCache(data))
        XCTAssertFalse(ScanHistoryThumbnailRenderer.isValidCache(Data()))
        XCTAssertFalse(ScanHistoryThumbnailRenderer.isValidCache(Data("not a PNG".utf8)))
        XCTAssertFalse(ScanHistoryThumbnailRenderer.isValidCache(Data(data.prefix(data.count - 12))))
        XCTAssertFalse(ScanHistoryThumbnailRenderer.isValidCache(Data(repeating: 0, count: 2 * 1_024 * 1_024 + 1)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: 128, height: 128)))
        let smaller = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(smaller, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cropped, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertFalse(ScanHistoryThumbnailRenderer.isValidCache(smaller as Data))
    }

    func testDegenerateAndInvalidPositionsStayBounded() throws {
        let one = try ScanHistoryThumbnailRenderer.render(mesh([vertex(0, 0, 0)]))
        XCTAssertTrue(ScanHistoryThumbnailRenderer.isValidCache(one))
        XCTAssertGreaterThan(try pixels(one).nonBackgroundCoordinates.count, 0)
        let line = (0..<30).map { vertex(0, Float($0) * 0.002, 0.02) }
        XCTAssertTrue(ScanHistoryThumbnailRenderer.isValidCache(try ScanHistoryThumbnailRenderer.render(mesh(line))))
        var invalidColor = vertex(0, 0, 0)
        invalidColor.color.y = .nan
        let invalid = [vertex(.nan, 0, 0), vertex(.greatestFiniteMagnitude, 0, 0), invalidColor]
        XCTAssertThrowsError(try ScanHistoryThumbnailRenderer.render(mesh([])))
        XCTAssertThrowsError(try ScanHistoryThumbnailRenderer.render(mesh(invalid)))
        let mixed = try ScanHistoryThumbnailRenderer.render(mesh(invalid + [vertex(0, 0, 0)]))
        XCTAssertEqual(mixed, one, "Non-renderable points must not destroy the framing of valid points.")
    }

    func testLargeCloudSamplesAcrossTheWholeSourceAndKeepsItsSilhouette() throws {
        var vertices: [ScanVertex] = []
        for row in 0..<200 { for column in 0..<400 {
            let color = column < 200 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)
            vertices.append(vertex(Float(column) * 0.0005 - 0.1, Float(row) * 0.0005 - 0.05,
                                   0.02, color: color))
        }}
        let data = try ScanHistoryThumbnailRenderer.render(mesh(vertices))
        let picture = try pixels(data)
        let left = try XCTUnwrap(picture.centroid { $0.1 > 150 && $0.0 < 80 && $0.2 < 80 })
        let right = try XCTUnwrap(picture.centroid { $0.2 > 150 && $0.0 < 80 && $0.1 < 80 })
        XCTAssertLessThan(left.x, right.x)
        XCTAssertGreaterThan(picture.nonBackgroundCoordinates.count, 10_000)
        XCTAssertTrue(picture.nonBackgroundCoordinates.allSatisfy {
            $0.x >= 12 && $0.x <= 244 && $0.y >= 12 && $0.y <= 244
        })
    }

    func testCancelledRenderingDoesNotPublishAPNG() async throws {
        let source = mesh([vertex(0, 0, 0)])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ScanHistoryThumbnailRenderer.render(source)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled rendering must not produce a cache payload.")
        } catch is CancellationError {}
    }

    private func vertex(_ x: Float, _ y: Float, _ z: Float,
                        color: SIMD3<Float> = SIMD3(0.75, 0.55, 0.4)) -> ScanVertex {
        ScanVertex(position: SIMD3(x, y, z), color: color)
    }

    private func mesh(_ vertices: [ScanVertex]) -> ScanMesh {
        ScanMesh(vertices: vertices, triangleIndices: [], frameCount: 8, coveredAngles: [.center])
    }

    private struct Picture {
        let bytes: [UInt8]
        let width: Int
        let height: Int

        var nonBackgroundCoordinates: [CGPoint] {
            var result: [CGPoint] = []
            for row in 0..<height { for column in 0..<width {
                let offset = (row * width + column) * 4
                if abs(Int(bytes[offset]) - 40) + abs(Int(bytes[offset + 1]) - 34) + abs(Int(bytes[offset + 2]) - 29) > 12 {
                    result.append(CGPoint(x: column, y: row))
                }
            }}
            return result
        }

        func centroid(where matches: ((Int, Int, Int)) -> Bool) -> CGPoint? {
            var x = 0.0, y = 0.0, count = 0
            for row in 0..<height { for column in 0..<width {
                let offset = (row * width + column) * 4
                if matches((Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))) {
                    x += Double(column); y += Double(row); count += 1
                }
            }}
            return count > 0 ? CGPoint(x: x / Double(count), y: y / Double(count)) : nil
        }
    }

    private func pixels(_ data: Data) throws -> Picture {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pointer = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        return Picture(bytes: Array(UnsafeBufferPointer(start: pointer, count: image.width * image.height * 4)),
                       width: image.width, height: image.height)
    }
}

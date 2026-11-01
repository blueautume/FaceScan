import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

/// A small, deterministic view of the stored points. Rendering uses no camera,
/// surface reconstruction or mutable SceneKit state, so it can run off the UI
/// actor while a history row is appearing.
enum ScanHistoryThumbnailRenderer {
    nonisolated static let pixelSize = 256
    nonisolated static let maximumCacheBytes = 2 * 1_024 * 1_024
    private nonisolated static let maximumSourcePoints = 500_000
    private nonisolated static let maximumDrawnPoints = 50_000
    private nonisolated static let background: [UInt8] = [40, 34, 29, 255]

    enum RenderError: LocalizedError {
        case noRenderablePoints
        case tooManyPoints
        case cannotEncode

        var errorDescription: String? {
            switch self {
            case .noRenderablePoints: String(localized: "This scan has no valid points for a preview.")
            case .tooManyPoints: String(localized: "This scan has too many points to generate a preview.")
            case .cannotEncode: String(localized: "Couldn't generate a point cloud preview.")
            }
        }
    }

    nonisolated static func render(_ mesh: ScanMesh) throws -> Data {
        try Task.checkCancellation()
        guard mesh.vertices.count <= maximumSourcePoints else { throw RenderError.tooManyPoints }
        var valid: [Int] = []
        valid.reserveCapacity(mesh.vertices.count)
        var sourceLow = SIMD3<Double>(repeating: .infinity)
        var sourceHigh = SIMD3<Double>(repeating: -.infinity)
        for (index, vertex) in mesh.vertices.enumerated() {
            if index.isMultiple(of: 1_024) { try Task.checkCancellation() }
            guard isRenderable(vertex) else { continue }
            let point = SIMD3<Double>(vertex.position)
            sourceLow = simd_min(sourceLow, point)
            sourceHigh = simd_max(sourceHigh, point)
            valid.append(index)
        }
        guard !valid.isEmpty else { throw RenderError.noRenderablePoints }
        let sourceCenter = (sourceLow + sourceHigh) * 0.5

        // Frame after rotating: a protruding nose and the slanted jaw must fit
        // inside the same margin as the measured frontal silhouette.
        var low = SIMD2<Double>(repeating: .infinity)
        var high = SIMD2<Double>(repeating: -.infinity)
        for (ordinal, index) in valid.enumerated() {
            if ordinal.isMultiple(of: 1_024) { try Task.checkCancellation() }
            let point = rotate(SIMD3<Double>(mesh.vertices[index].position) - sourceCenter)
            let projected = SIMD2(point.x, point.y)
            low = simd_min(low, projected)
            high = simd_max(high, projected)
        }
        let center = (low + high) * 0.5
        // A degenerate single point or line still has a stable finite framing.
        let extent = max(0.0001, max(high.x - low.x, high.y - low.y))
        let scale = Double(pixelSize - 1 - 32) / extent
        let imageCenter = Double(pixelSize - 1) * 0.5
        let drawnCount = min(valid.count, maximumDrawnPoints)
        var pixels = [UInt8](repeating: 0, count: pixelSize * pixelSize * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = background[0]
            pixels[index + 1] = background[1]
            pixels[index + 2] = background[2]
            pixels[index + 3] = 255
        }
        var depth = [Double](repeating: -.infinity, count: pixelSize * pixelSize)
        let radius = 0.85
        for ordinal in 0..<drawnCount {
            if ordinal.isMultiple(of: 512) { try Task.checkCancellation() }
            // Include both ends and sample across the full acquisition order,
            // rather than discarding the last side of a large accumulated scan.
            let selected = drawnCount == 1 ? 0 : ordinal * (valid.count - 1) / (drawnCount - 1)
            let vertex = mesh.vertices[valid[selected]]
            let point = rotate(SIMD3<Double>(vertex.position) - sourceCenter)
            let x = imageCenter + (point.x - center.x) * scale
            let y = imageCenter - (point.y - center.y) * scale // +Y is up in the stored scan.
            let minX = max(0, Int(floor(x - radius - 0.5)))
            let maxX = min(pixelSize - 1, Int(ceil(x + radius + 0.5)))
            let minY = max(0, Int(floor(y - radius - 0.5)))
            let maxY = min(pixelSize - 1, Int(ceil(y + radius + 0.5)))
            guard minX <= maxX, minY <= maxY else { continue }
            let color = SIMD3<Double>(vertex.color) * 255
            for row in minY...maxY { for column in minX...maxX {
                let distance = hypot(Double(column) + 0.5 - x, Double(row) + 0.5 - y)
                let coverage = min(1, max(0, radius + 0.5 - distance))
                guard coverage > 0 else { continue }
                let sample = row * pixelSize + column
                // The camera looks toward -Z after rotation, hence larger Z is
                // nearer. Rear points cannot paint over the face in front.
                guard point.z >= depth[sample] else { continue }
                depth[sample] = point.z
                for component in 0..<3 {
                    let value = color[component] * coverage + Double(background[component]) * (1 - coverage)
                    pixels[sample * 4 + component] = UInt8(value.rounded())
                }
            }}
        }
        try Task.checkCancellation()
        let bitmap = Data(pixels)
        guard let provider = CGDataProvider(data: bitmap as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: pixelSize, height: pixelSize, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: pixelSize * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                                    .union(.byteOrder32Big),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { throw RenderError.cannotEncode }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.cannotEncode
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.cannotEncode }
        try Task.checkCancellation()
        return output as Data
    }

    /// The cache is derived and replaceable. Bound encoded bytes and dimensions
    /// before asking ImageIO to decode any cached file from disk.
    nonisolated static func isValidCache(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumCacheBytes,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              data.suffix(12).elementsEqual([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == pixelSize,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == pixelSize,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == pixelSize, image.height == pixelSize,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8,
                                      bytesPerRow: pixelSize * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        return CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    }

    private nonisolated static func isRenderable(_ vertex: ScanVertex) -> Bool {
        let p = vertex.position, c = vertex.color
        return p.x.isFinite && p.y.isFinite && p.z.isFinite
            && abs(p.x) <= 2 && abs(p.y) <= 2 && abs(p.z) <= 2
            && c.x.isFinite && c.y.isFinite && c.z.isFinite
            && (0...1).contains(c.x) && (0...1).contains(c.y) && (0...1).contains(c.z)
    }

    private nonisolated static func rotate(_ point: SIMD3<Double>) -> SIMD3<Double> {
        let yaw = -25.0 * .pi / 180
        let pitch = -10.0 * .pi / 180
        let x = cos(yaw) * point.x + sin(yaw) * point.z
        let z = -sin(yaw) * point.x + cos(yaw) * point.z
        return SIMD3(x, cos(pitch) * point.y - sin(pitch) * z,
                     sin(pitch) * point.y + cos(pitch) * z)
    }
}

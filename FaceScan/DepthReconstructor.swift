import ARKit
import AVFoundation
import CoreVideo
import Foundation
import simd

/// CPU-based local depth reconstruction. All methods must run
/// on the same serial worker queue. ARKit supplies a rigid pose and a loose ROI;
/// EVERY exported position is measured from capturedDepthData, never copied
/// from ARFaceGeometry. This is a fused visible face surface, not a watertight
/// head, and is not intended for clinical measurements.
final class DepthReconstructor {
    private let voxelSize: Float = 0.002
    private let maximumVertices = 180_000
    private let maximumTriangles = 400_000
    private var spatialIndex = PointFusionSpatialIndex()
    private var accumulators: [PointFusionAccumulator] = []
    private var triangles: [ScanTriangle] = []
    private var triangleKeys: Set<TriangleKey> = []
    private var acceptedFrames = 0
    private var coverage = ScanCoverageTracker()
    private var fusionBudget = ScanFusionBudget()
    private var lastDepthTimestamp: TimeInterval?
    private var lastPose: (timestamp: TimeInterval, yaw: Float, pitch: Float)?
    private var trackedFaceIdentifier: UUID?

    init() {}

    func reset() {
        spatialIndex.reset()
        accumulators.removeAll(keepingCapacity: true)
        triangles.removeAll(keepingCapacity: true)
        triangleKeys.removeAll(keepingCapacity: true)
        coverage.reset()
        fusionBudget.reset()
        acceptedFrames = 0
        lastDepthTimestamp = nil
        lastPose = nil
        trackedFaceIdentifier = nil
    }

    func integrate(frame: ARFrame, face: ARFaceAnchor) -> ScanProgress {
        guard face.isTracked else { return progress("正在寻找人脸，请看向镜头") }
        if let identifier = trackedFaceIdentifier, identifier != face.identifier {
            return progress("人脸追踪已更换，请重新扫描以避免混合不同面部", requiresRestart: true)
        }
        guard let capturedDepth = frame.capturedDepthData else {
            return progress("正在等待 TrueDepth 深度画面")
        }

        // Color and depth have different frame rates. Do not fuse a stale depth
        // frame under a newer head pose, or integrate the same depth twice.
        let depthTimestamp = frame.capturedDepthDataTimestamp
        if depthTimestamp > 0 {
            guard abs(frame.timestamp - depthTimestamp) < 0.06 else {
                return progress("请缓慢转头，正在等待同步深度")
            }
            if let previous = lastDepthTimestamp, depthTimestamp <= previous {
                return progress(coverage.nextHint)
            }
        }

        let cameraToFace = simd_inverse(face.transform) * frame.camera.transform
        let cameraInFace = cameraToFace.columns.3.xyz
        let distance = simd_length(cameraInFace)
        guard distance.isFinite, distance >= 0.23 else {
            return progress("离镜头稍远一些，保持约 30–55 厘米")
        }
        guard distance <= 0.70 else {
            return progress("靠近一些，让脸占据取景框中央")
        }

        // Measuring the camera direction in anatomical face axes avoids making
        // yaw depend on whether the phone is held in portrait or landscape.
        let yaw = atan2(cameraInFace.x, cameraInFace.z)
        let pitch = atan2(cameraInFace.y, hypot(cameraInFace.x, cameraInFace.z))
        guard cameraInFace.z > 0, abs(yaw) <= ScanCoverageTracker.maximumYaw else {
            return progress("转头角度稍小一些，保持面部仍被追踪")
        }
        guard abs(pitch) <= ScanCoverageTracker.maximumPitch else {
            return progress("抬头或低头幅度稍小一些，让额头和下颌保持可见")
        }
        guard neutralExpression(face) else {
            return progress("请放松表情、闭嘴，眼睛自然睁开")
        }
        if let previous = lastPose {
            let elapsed = frame.timestamp - previous.timestamp
            if elapsed > 0, elapsed < 0.6,
               (abs(yaw - previous.yaw) / Float(elapsed) > radians(55)
                || abs(pitch - previous.pitch) / Float(elapsed) > radians(45)) {
                return progress("转头慢一点，让深度画面保持稳定")
            }
        }

        let depth = capturedDepth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        // Relative depth cannot support a metric reconstruction. TrueDepth
        // normally provides absolute depth; do not silently label a relative
        // estimate as meters on an unsupported capture configuration.
        guard depth.depthDataAccuracy == .absolute else {
            return progress("当前深度不是绝对距离，无法生成米制扫描")
        }
        let depthBuffer = depth.depthDataMap
        let imageBuffer = frame.capturedImage
        let width = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)
        guard width > 2, height > 2 else { return progress("深度画面暂不可用") }
        let depthAspect = Float(width) / Float(height)
        let colorAspect = Float(CVPixelBufferGetWidth(imageBuffer))
            / Float(CVPixelBufferGetHeight(imageBuffer))
        guard abs(depthAspect - colorAspect) < 0.025 else {
            // Scaling mismatched crops without the crop transform would produce
            // plausible-looking but incorrectly registered vertex colors.
            return progress("当前彩色与深度画面比例不匹配，请重新开始")
        }
        guard let projection = DepthProjection(depth: depth, camera: frame.camera,
                                               width: width, height: height) else {
            return progress("相机校准数据暂不可用")
        }
        guard CVPixelBufferLockBaseAddress(depthBuffer, .readOnly) == kCVReturnSuccess else {
            return progress("无法读取深度画面")
        }
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }
        guard CVPixelBufferLockBaseAddress(imageBuffer, .readOnly) == kCVReturnSuccess else {
            return progress("无法读取相机颜色")
        }
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthBuffer),
              let colors = CameraColors(buffer: imageBuffer),
              let bounds = FaceBounds(geometry: face.geometry) else {
            return progress("正在准备扫描数据")
        }

        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthBuffer)
        // 640-pixel depth maps use a 2-pixel stride; a 320-pixel map retains its
        // native samples. Faces remain small enough for a serial CPU demo.
        let step = max(1, width / 320)
        let columns = (width + step - 1) / step
        let rows = (height + step - 1) / step
        var samples = [FrameSample?](repeating: nil, count: columns * rows)
        var validCount = 0

        for row in 0..<rows {
            let y = row * step
            let depthRow = depthBase.advanced(by: y * depthRowBytes)
                .assumingMemoryBound(to: Float.self)
            for column in 0..<columns {
                let x = column * step
                let z = depthRow[x]
                // The foreground depth interval must include the enlarged
                // forehead/chin/side ROI at oblique poses. The face-space crop
                // below remains the final boundary; this is only a cheap range
                // rejection, not permission to merge nearby background.
                guard z.isFinite, z >= 0.15, z <= 1.0,
                      abs(z - distance) <= bounds.maximumRadius + 0.025 else { continue }
                let optical = projection.point(x: x, y: y, depth: z)
                // AVDepthData uses optical +Y down/+Z forward. ARKit uses +Y
                // up/-Z forward. Never apply a portrait display transform to
                // these raw, unmirrored sensor pixels.
                let facePosition = DepthGeometry.facePoint(fromOptical: optical,
                                                           cameraToFace: cameraToFace)
                guard bounds.contains(facePosition) else { continue }
                let color = colors.color(normalizedX: (Float(x) + 0.5) / Float(width),
                                         normalizedY: (Float(y) + 0.5) / Float(height))
                samples[row * columns + column] = FrameSample(position: facePosition,
                                                              color: color, depth: z)
                validCount += 1
            }
        }

        guard validCount >= 250 else {
            return progress("有效深度偏少，请调整光线并保持脸在中央")
        }

        trackedFaceIdentifier = face.identifier
        acceptedFrames += 1
        if depthTimestamp > 0 { lastDepthTimestamp = depthTimestamp }
        lastPose = (frame.timestamp, yaw, pitch)
        let budgetAngle = ScanFusionBudget.angle(yaw: yaw, pitch: pitch)
        var indices = [Int](repeating: -1, count: samples.count)
        for index in samples.indices {
            guard let sample = samples[index] else { continue }
            indices[index] = fuse(sample, frameNumber: acceptedFrames, angle: budgetAngle)
        }

        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let a = row * columns + column
                let b = a + 1
                let c = a + columns
                let d = c + 1
                addTriangle(a, c, b, indices: indices, samples: samples,
                            cameraInFace: cameraInFace, angle: budgetAngle)
                addTriangle(b, c, d, indices: indices, samples: samples,
                            cameraInFace: cameraInFace, angle: budgetAngle)
            }
        }

        // Coverage follows the confirmed point cloud, including regions where
        // depth holes or the triangle budget prevent connected surface patches.
        // Repeated pixels for one point still count only once.
        coverage.observe(yaw: yaw, pitch: pitch,
                         acceptedPoints: ScanSurfaceBuilder.confirmedPointCount(
                            in: indices, accumulators: accumulators))
        return progress(coverage.nextHint)
    }

    /// Produces a bounded point-only preview on the serial reconstruction queue.
    /// Does not remap or traverse triangles, or invoke final mesh generation.
    func makePointCloudSnapshot(maximumPoints: Int = 24_000) -> LivePointCloudSnapshot? {
        LivePointCloudSampler.makeSnapshot(
            sourceCount: accumulators.count, revision: acceptedFrames,
            maximumPoints: maximumPoints,
            observedFramesAt: { accumulators[$0].observedFrames },
            vertexAt: { index in
                let accumulator = accumulators[index]
                return ScanVertex(position: accumulator.position, color: accumulator.color)
            })
    }

    func makeMesh() -> ScanMesh? {
        ScanSurfaceBuilder.makeMesh(accumulators: accumulators, triangles: triangles,
                                    frameCount: acceptedFrames,
                                    coveredAngles: coverage.coveredAngles)
    }

    private func progress(_ hint: String, requiresRestart: Bool = false) -> ScanProgress {
        ScanProgress(acceptedFrames: acceptedFrames, vertexCount: accumulators.count,
                     coveredAngles: coverage.coveredAngles, hint: hint,
                     requiresRestart: requiresRestart)
    }

    private func neutralExpression(_ face: ARFaceAnchor) -> Bool {
        func amount(_ location: ARFaceAnchor.BlendShapeLocation) -> Float {
            face.blendShapes[location]?.floatValue ?? 0
        }
        return amount(.jawOpen) < 0.18
            && max(amount(.mouthSmileLeft), amount(.mouthSmileRight)) < 0.55
            && amount(.mouthPucker) < 0.45
            && max(amount(.eyeBlinkLeft), amount(.eyeBlinkRight)) < 0.85
    }

    private func fuse(_ sample: FrameSample, frameNumber: Int, angle: ScanAngle) -> Int {
        let sameCell = spatialIndex.indices(inSameCellAs: sample.position)
        if let index = PointFusionNeighborhood.nearestIndex(
            to: sample.position, candidateIndices: sameCell, maximumDistance: voxelSize * 2,
            positionAt: { accumulators[$0].position }) {
            guard accumulators[index].add(position: sample.position, color: sample.color,
                                          frameNumber: frameNumber) else { return -1 }
            spatialIndex.update(index: index, position: accumulators[index].position)
            return index
        }
        // Two measurements of the same surface can straddle a voxel boundary.
        // Reuse a genuinely nearby point rather than growing a second layer.
        // The small 3D radius does not join different depths across silhouettes.
        let candidates = spatialIndex.indices(inNeighborhoodOf: sample.position)
        if let index = PointFusionNeighborhood.nearestIndex(
            to: sample.position, candidateIndices: candidates, maximumDistance: 0.00125,
            positionAt: { accumulators[$0].position }) {
            guard accumulators[index].add(position: sample.position, color: sample.color,
                                          frameNumber: frameNumber) else { return -1 }
            spatialIndex.update(index: index, position: accumulators[index].position)
            return index
        }
        guard accumulators.count < maximumVertices,
              fusionBudget.reserveVertex(for: angle) else { return -1 }
        let index = accumulators.count
        accumulators.append(PointFusionAccumulator(position: sample.position, color: sample.color,
                                                  frameNumber: frameNumber))
        spatialIndex.update(index: index, position: sample.position)
        return index
    }

    @discardableResult
    private func addTriangle(_ i: Int, _ j: Int, _ k: Int,
                             indices: [Int], samples: [FrameSample?],
                             cameraInFace: SIMD3<Float>, angle: ScanAngle) -> Bool {
        guard indices[i] >= 0, indices[j] >= 0, indices[k] >= 0,
              indices[i] != indices[j], indices[j] != indices[k], indices[i] != indices[k],
              let p = samples[i], let q = samples[j], let r = samples[k] else { return false }
        let maximumDepth = max(p.depth, max(q.depth, r.depth))
        let minimumDepth = min(p.depth, min(q.depth, r.depth))
        // Never bridge an occlusion, the nose silhouette, or a hole in depth.
        guard maximumDepth - minimumDepth < 0.009,
              simd_distance(p.position, q.position) < 0.012,
              simd_distance(q.position, r.position) < 0.012,
              simd_distance(r.position, p.position) < 0.012 else { return false }
        let normal = simd_cross(q.position - p.position, r.position - p.position)
        guard simd_length_squared(normal) > 1e-13 else { return false }
        let key = TriangleKey(indices[i], indices[j], indices[k])
        // Already fused patches remain useful evidence even when this view's
        // allowance for new triangles is full. Duplicate patches cost nothing.
        if triangleKeys.contains(key) { return true }
        guard triangles.count < maximumTriangles,
              fusionBudget.reserveTriangle(for: angle) else { return false }
        triangleKeys.insert(key)
        // Orient each measured patch toward the camera which observed it.
        if simd_dot(normal, cameraInFace - p.position) >= 0 {
            triangles.append(ScanTriangle(a: indices[i], b: indices[j], c: indices[k]))
        } else {
            triangles.append(ScanTriangle(a: indices[i], b: indices[k], c: indices[j]))
        }
        return true
    }

    private func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }
}

/// Keeps long straight-on scans from exhausting the storage reserved for the
/// forehead, chin and side views. Updating an existing voxel/triangle bypasses
/// this budget in the live path; only genuinely new geometry reserves space.
struct ScanFusionBudget {
    static let maximumVerticesPerAngle = 25_000
    static let maximumTrianglesPerAngle = 55_000
    private var vertexCounts: [ScanAngle: Int] = [:]
    private var triangleCounts: [ScanAngle: Int] = [:]

    mutating func reset() {
        vertexCounts.removeAll(keepingCapacity: true)
        triangleCounts.removeAll(keepingCapacity: true)
    }

    mutating func reserveVertex(for angle: ScanAngle) -> Bool {
        guard vertexCounts[angle, default: 0] < Self.maximumVerticesPerAngle else { return false }
        vertexCounts[angle, default: 0] += 1
        return true
    }

    mutating func reserveTriangle(for angle: ScanAngle) -> Bool {
        guard triangleCounts[angle, default: 0] < Self.maximumTrianglesPerAngle else { return false }
        triangleCounts[angle, default: 0] += 1
        return true
    }

    static func angle(yaw: Float, pitch: Float) -> ScanAngle {
        if let measuredView = ScanCoverageTracker.angle(yaw: yaw, pitch: pitch) {
            return measuredView
        }
        // Frames between guided target intervals can still contribute depth.
        // Charge their new geometry to the nearest target, without granting
        // coverage for an angle that was never actually observed.
        let radians: Float = .pi / 180
        let targets: [(ScanAngle, Float, Float)] = [
            (.center, 0, 0), (.left, -24, 0), (.farLeft, -45, 0),
            (.right, 24, 0), (.farRight, 45, 0),
            (.forehead, 0, 20), (.chin, 0, -20)
        ]
        var nearest = ScanAngle.center
        var nearestDistance = Float.infinity
        for (angle, targetYaw, targetPitch) in targets {
            let dy = yaw - targetYaw * radians
            let dp = pitch - targetPitch * radians
            let distance = dy * dy + dp * dp
            if distance < nearestDistance {
                nearest = angle
                nearestDistance = distance
            }
        }
        return nearest
    }
}

private struct FrameSample {
    var position: SIMD3<Float>
    var color: SIMD3<Float>
    var depth: Float
}

private struct TriangleKey: Hashable {
    var a: Int
    var b: Int
    var c: Int

    init(_ first: Int, _ second: Int, _ third: Int) {
        a = min(first, min(second, third))
        c = max(first, max(second, third))
        b = first + second + third - a - c
    }
}

/// A bounded foreground volume derived from the tracked face size. ARKit's
/// fitted mask stops before the full forehead, jaw margin and ears; its bounds
/// locate this crop but never supply reconstructed vertices.
struct FaceBounds {
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>

    init?(geometry: ARFaceGeometry) {
        self.init(vertices: geometry.vertices)
    }

    init?(vertices: [SIMD3<Float>]) {
        guard let first = vertices.first,
              vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            return nil
        }
        var low = first
        var high = first
        for vertex in vertices {
            low = simd_min(low, vertex)
            high = simd_max(high, vertex)
        }
        let extent = high - low
        let center = (high + low) * 0.5
        // Reject degenerate/non-metric geometry instead of turning a bad pose
        // into an unbounded foreground crop. Values are meters in face axes.
        guard extent.x >= 0.05, extent.x <= 0.26,
              extent.y >= 0.06, extent.y <= 0.32,
              extent.z >= 0.005, extent.z <= 0.22,
              simd_reduce_max(simd_abs(center)) <= 0.20 else { return nil }

        let scale = min(max(extent.x / 0.15, 0.85), 1.20)
        let side = 0.030 * scale
        let forehead = min(max(0.072 * scale, 0.065), 0.080)
        let chin = min(max(0.030 * scale, 0.025), 0.035)
        let rear = min(max(0.062 * scale, 0.055), 0.070)
        let front = 0.020 * scale
        minimum = low - SIMD3<Float>(side, chin, rear)
        maximum = high + SIMD3<Float>(side, forehead, front)
    }

    /// Encloses the complete crop around the face origin, including at yaw and
    /// pitch. Used only to avoid a narrower camera-depth prefilter.
    var maximumRadius: Float {
        simd_length(simd_max(simd_abs(minimum), simd_abs(maximum)))
    }

    func contains(_ point: SIMD3<Float>) -> Bool {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
              point.x >= minimum.x, point.x <= maximum.x,
              point.y >= minimum.y, point.y <= maximum.y,
              point.z >= minimum.z, point.z <= maximum.z else { return false }
        let center = (minimum + maximum) * 0.5
        let radius = (maximum - minimum) * 0.5
        let x = (point.x - center.x) / max(radius.x, 0.001)
        let y = (point.y - center.y) / max(radius.y, 0.001)
        // A rounded rectangular cross-section retains cheeks/ear-fronts that
        // an ellipse cuts away, while excluding the upper/lower corners where
        // background and shoulders otherwise enter. Depth remains bounded in
        // three dimensions; this does not fill unseen surfaces or holes.
        return x * x * x * x + y * y * y * y <= 1
    }
}

/// Pure coordinate operations shared by the live path and geometry tests.
enum DepthGeometry {
    static func opticalToARCamera(_ point: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(point.x, -point.y, -point.z)
    }

    static func facePoint(fromOptical point: SIMD3<Float>,
                          cameraToFace: simd_float4x4) -> SIMD3<Float> {
        let cameraPoint = opticalToARCamera(point)
        return (cameraToFace * SIMD4(cameraPoint.x, cameraPoint.y, cameraPoint.z, 1)).xyz
    }
}

/// Calibration refers to the unmirrored, sensor-native image, never the
/// portrait viewfinder. Its numeric constructor also makes the exact projection
/// mathematics testable without a device or an ARSession.
struct DepthProjection {
    let inverseIntrinsics: simd_float3x3
    let referenceScale: SIMD2<Float>
    let distortionCenter: SIMD2<Float>
    let distortionRadius: Float
    let inverseDistortion: [Float]

    init?(depth: AVDepthData, camera: ARCamera, width: Int, height: Int) {
        let calibration = depth.cameraCalibrationData
        let intrinsics = calibration?.intrinsicMatrix ?? camera.intrinsics
        let reference = calibration?.intrinsicMatrixReferenceDimensions ?? camera.imageResolution
        let center = calibration?.lensDistortionCenter ?? .zero
        let table: [Float]
        if let data = calibration?.inverseLensDistortionLookupTable,
           data.count >= MemoryLayout<Float>.size * 2 {
            table = data.withUnsafeBytes { raw in
                stride(from: 0, to: data.count - 3, by: MemoryLayout<Float>.size).map {
                    raw.loadUnaligned(fromByteOffset: $0, as: Float.self)
                }
            }
        } else {
            table = []
        }
        // AVDepthData is registered to its companion color image (including its
        // lens distortion). Thus its calibrated image axes are the same native
        // optical axes as ARFrame.capturedImage. Applying the physical depth-
        // sensor extrinsic AGAIN here would double-register the aligned map.
        // If AVDepthData omits calibration, ARCamera's image-space K is the
        // fallback; it cannot supply an absent distortion lookup table.
        self.init(intrinsics: intrinsics, referenceSize: reference,
                  depthSize: CGSize(width: width, height: height),
                  distortionCenter: center, inverseDistortion: table)
    }

    init?(intrinsics: simd_float3x3, referenceSize: CGSize, depthSize: CGSize,
          distortionCenter: CGPoint = .zero, inverseDistortion: [Float] = []) {
        guard referenceSize.width.isFinite, referenceSize.height.isFinite,
              depthSize.width.isFinite, depthSize.height.isFinite,
              referenceSize.width > 0, referenceSize.height > 0,
              depthSize.width > 0, depthSize.height > 0,
              intrinsics.columns.0.x > 0, intrinsics.columns.1.y > 0,
              intrinsics.columns.0.x.isFinite, intrinsics.columns.1.y.isFinite,
              abs(simd_determinant(intrinsics)) > 1e-8,
              inverseDistortion.allSatisfy(\.isFinite) else { return nil }
        self.inverseIntrinsics = simd_inverse(intrinsics)
        self.referenceScale = SIMD2(Float(referenceSize.width / depthSize.width),
                                    Float(referenceSize.height / depthSize.height))
        self.distortionCenter = SIMD2(Float(distortionCenter.x), Float(distortionCenter.y))
        let dx = max(Float(distortionCenter.x), Float(referenceSize.width - distortionCenter.x))
        let dy = max(Float(distortionCenter.y), Float(referenceSize.height - distortionCenter.y))
        self.distortionRadius = hypot(dx, dy)
        self.inverseDistortion = inverseDistortion
    }

    func point(x: Int, y: Int, depth: Float) -> SIMD3<Float> {
        // Apple defines principal point coordinates from the top-left CORNER
        // of the first pixel. Samples therefore lie at x+0.5/y+0.5.
        point(pixelCenter: SIMD2(Float(x) + 0.5, Float(y) + 0.5), depth: depth)
    }

    func point(pixelCenter: SIMD2<Float>, depth: Float) -> SIMD3<Float> {
        var pixel = pixelCenter * referenceScale
        if inverseDistortion.count >= 2, distortionRadius > 0 {
            let vector = pixel - distortionCenter
            let radius = simd_length(vector)
            let tablePosition = min(radius / distortionRadius, 1)
                * Float(inverseDistortion.count - 1)
            let lower = min(Int(tablePosition), inverseDistortion.count - 2)
            let fraction = tablePosition - Float(lower)
            let magnification = inverseDistortion[lower] * (1 - fraction)
                + inverseDistortion[lower + 1] * fraction
            // Apple's SDK reference implementation explicitly uses the
            // INVERSE table when mapping an existing distorted pixel to its
            // rectilinear location. The forward table is for reverse resampling.
            pixel = distortionCenter + vector * (1 + magnification)
        }
        return (inverseIntrinsics * SIMD3(pixel.x, pixel.y, 1)) * depth
    }
}

private struct CameraColors {
    let buffer: CVPixelBuffer
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let uses709: Bool

    init?(buffer: CVPixelBuffer) {
        self.buffer = buffer
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        let supported = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_32BGRA
        guard supported, width > 0, height > 0 else { return nil }
        if pixelFormat == kCVPixelFormatType_32BGRA {
            guard CVPixelBufferGetBaseAddress(buffer) != nil else { return nil }
        } else {
            guard CVPixelBufferGetPlaneCount(buffer) >= 2,
                  CVPixelBufferGetBaseAddressOfPlane(buffer, 0) != nil,
                  CVPixelBufferGetBaseAddressOfPlane(buffer, 1) != nil else { return nil }
        }
        let attachment = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil)
        uses709 = attachment as? String == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
    }

    func color(normalizedX: Float, normalizedY: Float) -> SIMD3<Float> {
        let x = min(max(Int(normalizedX * Float(width)), 0), width - 1)
        let y = min(max(Int(normalizedY * Float(height)), 0), height - 1)
        if pixelFormat == kCVPixelFormatType_32BGRA,
           let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
            let index = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            return SIMD3(Float(base[index + 2]), Float(base[index + 1]), Float(base[index])) / 255
        }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self) else {
            return SIMD3(repeating: 0.7)
        }
        let uvIndex = (y / 2) * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + (x / 2) * 2
        let rawY = Float(luma[y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + x])
        let rawCb = Float(chroma[uvIndex]) - 128
        let rawCr = Float(chroma[uvIndex + 1]) - 128
        let fullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let luminance = fullRange ? rawY / 255 : (rawY - 16) / 219
        let cb = rawCb / (fullRange ? 255 : 224)
        let cr = rawCr / (fullRange ? 255 : 224)
        let rgb: SIMD3<Float>
        if uses709 {
            rgb = SIMD3(luminance + 1.5748 * cr,
                        luminance - 0.187324 * cb - 0.468124 * cr,
                        luminance + 1.8556 * cb)
        } else {
            rgb = SIMD3(luminance + 1.402 * cr,
                        luminance - 0.344136 * cb - 0.714136 * cr,
                        luminance + 1.772 * cb)
        }
        return simd_clamp(rgb, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

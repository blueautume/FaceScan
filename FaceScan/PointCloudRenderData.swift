import Foundation
import SceneKit
import UIKit
import simd

/// Immutable packed bytes cross the preparation queue; SceneKit objects stay on the UI actor.
struct PointCloudRenderData: Sendable {
    let vertexData: Data
    let pointIndexData: Data
    let pointCount: Int
    let surfaceIndexData: Data
    let center: SIMD3<Float>?
    /// Two Float32 values per particle: birth time and a stable seed in 0...1.
    /// A negative birth encodes an unpresented delay as -(1 + delay).
    let birthData: Data?
    let preparationTime: TimeInterval
    let historicalAnimationEndTime: TimeInterval?
    let latestPendingBirthEndOffset: TimeInterval?

    /// Compatibility estimate. A displayed batch must instead use the actual
    /// presentation timestamp so background packing does not consume its flight.
    var animationEndTime: TimeInterval? { animationEndTime(presentedAt: preparationTime) }

    func animationEndTime(presentedAt time: TimeInterval) -> TimeInterval? {
        guard birthData != nil else { return nil }
        let shownAt = time.isFinite ? time : preparationTime
        let pendingEnd = latestPendingBirthEndOffset.map { shownAt + $0 }
        switch (historicalAnimationEndTime, pendingEnd) {
        case let (historical?, pending?): return max(historical, pending)
        case let (historical?, nil): return historical
        case let (nil, pending?): return pending
        case (nil, nil): return nil
        }
    }
}

/// A single serial preparation worker owns the workspace and particle history.
final class PointCloudRenderDataBuilder {
    private var values: [Float] = []
    private var remapping: [Int] = []
    private var surfaceIndices: [UInt32] = []
    private var birthValues: [Float] = []
    private var sequentialIndices: [UInt32] = []
    private var cachedPointCount = -1
    private var cachedPointIndices = Data()
    private var births: [ParticleIdentity: Birth] = [:]
    private var endTime: TimeInterval = 0
    private var recordingBirths = false
    private var originalBirths: [ParticleIdentity: OriginalBirth] = [:]
    private var pendingBirths: Set<ParticleIdentity> = []
    private var historyBeforeClear: [ParticleIdentity: Birth]?
    private var originalEndTime: TimeInterval = 0

    private enum ParticleIdentity: Hashable {
        case measured(UInt64)
        case fixture(PositionKey)

        var seed: Float {
            let hash: UInt64
            switch self {
            case .measured(let id):
                hash = Self.mix(id ^ 0xA0761D6478BD642F)
            case .fixture(let key):
                let x = Self.mix(UInt64(bitPattern: key.x) ^ 0xE7037ED1A0B428DB)
                let y = Self.mix(UInt64(bitPattern: key.y) ^ 0x8EBC6AF09C88C6E3)
                let z = Self.mix(UInt64(bitPattern: key.z) ^ 0x589965CC75374CC3)
                hash = Self.mix(x ^ y ^ z)
            }
            // Float32 exactly represents these 24-bit integers. The result is
            // reproducible across process launches, unlike Swift.Hasher.
            return Float(hash >> 40) / Float(0xFF_FFFF)
        }

        private static func mix(_ input: UInt64) -> UInt64 {
            var value = input &+ 0x9E3779B97F4A7C15
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }
    }

    /// A precise fallback for explicit fixtures that do not carry fusion IDs.
    /// Distinct nearby measured points must never inherit a neighbour's birth.
    private struct PositionKey: Hashable {
        let x: Int64
        let y: Int64
        let z: Int64

        init(_ position: SIMD3<Float>) {
            x = Int64((Double(position.x) * 1_000_000).rounded())
            y = Int64((Double(position.y) * 1_000_000).rounded())
            z = Int64((Double(position.z) * 1_000_000).rounded())
        }
    }

    private struct Birth {
        var time: Float
        let seed: Float
    }

    private struct OriginalBirth {
        let value: Birth?
    }

    func reset() {
        recordingBirths = false
        originalBirths.removeAll(keepingCapacity: true)
        pendingBirths.removeAll(keepingCapacity: true)
        historyBeforeClear = nil
        births.removeAll(keepingCapacity: true)
        endTime = 0
    }

    // New births remain pending until the main actor reports that geometry was
    // actually mounted. A rejected or unmounted batch consumes no flight.
    func beginPreparation() {
        precondition(!recordingBirths)
        recordingBirths = true
        originalEndTime = endTime
    }

    func finishPreparation(accepted: Bool, presentedAt: TimeInterval? = nil) {
        guard recordingBirths else { return }
        if accepted, let presentedAt, presentedAt.isFinite {
            let shownAt = max(PointCloudAnimationTime.origin, presentedAt)
            let shaderTime = PointCloudAnimationTime.shaderTime(at: shownAt)
            for identity in pendingBirths {
                guard var birth = births[identity], birth.time < 0 else { continue }
                let delay = -birth.time - 1
                birth.time = shaderTime + delay
                births[identity] = birth
                endTime = max(endTime, PointCloudAnimationTime.origin + Double(birth.time)
                              + Self.duration(for: birth.seed))
            }
        } else {
            if let historyBeforeClear {
                births = historyBeforeClear
            } else {
                for (identity, original) in originalBirths { births[identity] = original.value }
            }
            endTime = originalEndTime
        }
        recordingBirths = false
        originalBirths.removeAll(keepingCapacity: true)
        pendingBirths.removeAll(keepingCapacity: true)
        historyBeforeClear = nil
    }

    private func clearBirthHistory() {
        if recordingBirths, historyBeforeClear == nil {
            var original = births
            for (identity, previous) in originalBirths { original[identity] = previous.value }
            historyBeforeClear = original
        }
        births.removeAll(keepingCapacity: true)
        pendingBirths.removeAll(keepingCapacity: true)
    }

    /// Outside an explicit preparation transaction, `time` is treated as an
    /// immediate presentation timestamp for synchronous fixtures and tools.
    /// The production pipeline always brackets work with begin/finish ACKs.
    func prepare(vertices: [ScanVertex], pointIDs: [UInt64]? = nil,
                 triangleIndices: [UInt32] = [], animates: Bool = false,
                 time: TimeInterval = 0) -> PointCloudRenderData {
        let preparationTime = time.isFinite ? max(PointCloudAnimationTime.origin, time)
            : PointCloudAnimationTime.origin
        let validIDs = pointIDs?.count == vertices.count ? pointIDs : nil
        values.removeAll(keepingCapacity: true)
        values.reserveCapacity(vertices.count * 6)
        surfaceIndices.removeAll(keepingCapacity: true)
        birthValues.removeAll(keepingCapacity: true)
        if animates { birthValues.reserveCapacity(vertices.count * 2) }
        let hasSurface = !triangleIndices.isEmpty
        remapping.removeAll(keepingCapacity: true)
        if hasSurface {
            remapping.reserveCapacity(vertices.count)
            remapping.append(contentsOf: repeatElement(-1, count: vertices.count))
        }
        var pendingEndOffset: TimeInterval?
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        for (index, vertex) in vertices.enumerated() {
            guard Self.isRenderable(vertex) else { continue }
            if hasSurface { remapping[index] = values.count / 6 }
            let position = vertex.position
            let color = vertex.color
            values.append(position.x)
            values.append(position.y)
            values.append(position.z)
            values.append(color.x)
            values.append(color.y)
            values.append(color.z)
            low = simd_min(low, position)
            high = simd_max(high, position)
            if animates {
                let identity = validIDs.map { ParticleIdentity.measured($0[index]) }
                    ?? .fixture(PositionKey(position))
                let birth = birth(for: identity, at: preparationTime)
                birthValues.append(birth.time)
                birthValues.append(birth.seed)
                if birth.time < 0 {
                    let offset = Double(-birth.time - 1) + Self.duration(for: birth.seed)
                    pendingEndOffset = max(pendingEndOffset ?? 0, offset)
                }
            }
        }

        let pointCount = values.count / 6
        if pointCount == 0 {
            clearBirthHistory()
            endTime = 0
        }
        if hasSurface, pointCount > 0 {
            surfaceIndices.reserveCapacity(triangleIndices.count)
            let completeCount = triangleIndices.count - triangleIndices.count % 3
            for offset in stride(from: 0, to: completeCount, by: 3) {
                let originalA = Int(triangleIndices[offset])
                let originalB = Int(triangleIndices[offset + 1])
                let originalC = Int(triangleIndices[offset + 2])
                guard originalA < remapping.count, originalB < remapping.count,
                      originalC < remapping.count else { continue }
                let a = remapping[originalA]
                let b = remapping[originalB]
                let c = remapping[originalC]
                guard a >= 0, b >= 0, c >= 0, a != b, b != c, a != c,
                      simd_length_squared(simd_cross(vertices[originalB].position - vertices[originalA].position,
                                                     vertices[originalC].position - vertices[originalA].position)) > 1e-16 else {
                    continue
                }
                surfaceIndices.append(UInt32(a))
                surfaceIndices.append(UInt32(b))
                surfaceIndices.append(UInt32(c))
            }
        }
        if cachedPointCount != pointCount {
            sequentialIndices.removeAll(keepingCapacity: true)
            sequentialIndices.reserveCapacity(pointCount)
            for index in 0..<pointCount { sequentialIndices.append(UInt32(index)) }
            cachedPointIndices = sequentialIndices.withUnsafeBytes { Data($0) }
            cachedPointCount = pointCount
        }
        return PointCloudRenderData(
            vertexData: values.withUnsafeBytes { Data($0) },
            pointIndexData: cachedPointIndices,
            pointCount: pointCount,
            surfaceIndexData: surfaceIndices.withUnsafeBytes { Data($0) },
            center: pointCount > 0 ? (low + high) * 0.5 : nil,
            birthData: animates && pointCount > 0 ? birthValues.withUnsafeBytes { Data($0) } : nil,
            preparationTime: preparationTime,
            historicalAnimationEndTime: animates && pointCount > 0 && endTime > 0 ? endTime : nil,
            latestPendingBirthEndOffset: pendingEndOffset)
    }

    static func isRenderable(_ vertex: ScanVertex) -> Bool {
        let p = vertex.position
        let c = vertex.color
        return p.x.isFinite && p.y.isFinite && p.z.isFinite
            && c.x.isFinite && c.y.isFinite && c.z.isFinite
            && abs(p.x) <= 2 && abs(p.y) <= 2 && abs(p.z) <= 2
            && (0...1).contains(c.x) && (0...1).contains(c.y) && (0...1).contains(c.z)
    }

    private func birth(for identity: ParticleIdentity, at time: TimeInterval) -> Birth {
        if let previous = births[identity] { return previous }
        let seed = identity.seed
        let delay = Float(Double(seed) * PointCloudParticleStyle.revealSpread)
        let start = recordingBirths ? -(1 + delay)
            : PointCloudAnimationTime.shaderTime(at: time) + delay
        let birth = Birth(time: start, seed: seed)
        if recordingBirths {
            if historyBeforeClear == nil, originalBirths[identity] == nil {
                originalBirths[identity] = OriginalBirth(value: nil)
            }
            pendingBirths.insert(identity)
        } else {
            endTime = max(endTime, PointCloudAnimationTime.origin + Double(start) + Self.duration(for: seed))
        }
        births[identity] = birth
        return birth
    }

    private static func duration(for seed: Float) -> TimeInterval {
        PointCloudParticleStyle.duration(seed: seed)
    }
}

/// Only wraps prepared immutable bytes; material and point-element caches are bounded.
@MainActor
final class PointCloudRenderResources {
    private let material: SCNMaterial
    private let flightMaterial: SCNMaterial
    private var cachedPointCount = -1
    private var cachedPointElement: SCNGeometryElement?
    private(set) var pointSizeScale: Double = 1

    init() {
        material = Self.makeMaterial()
        flightMaterial = Self.makeMaterial()
        flightMaterial.shaderModifiers = [.geometry: PointCloudFlight.shader]
    }

    /// Point size is a presentation property. Updating the shared element keeps
    /// packed vertex/color buffers and every existing geometry source intact.
    @discardableResult
    func updatePointSizeScale(_ value: Double) -> Bool {
        let scale = Self.normalizedPointSizeScale(value)
        guard scale != pointSizeScale else { return false }
        pointSizeScale = scale
        if let element = cachedPointElement { applyPointSize(to: element) }
        return true
    }

    nonisolated static func normalizedPointSizeScale(_ value: Double) -> Double {
        value.isFinite ? min(4, max(0.25, value)) : 1
    }

    private func applyPointSize(to element: SCNGeometryElement) {
        element.pointSize = 0.0014 * pointSizeScale
        element.minimumPointScreenSpaceRadius = 1.4 * pointSizeScale
        element.maximumPointScreenSpaceRadius = 2 * pointSizeScale
    }

    func make(data: PointCloudRenderData) -> (points: SCNGeometry?, surface: SCNGeometry?) {
        guard data.pointCount > 0 else { return (nil, nil) }
        let positions = SCNGeometrySource(
            data: data.vertexData, semantic: .vertex, vectorCount: data.pointCount,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: 24)
        let colors = SCNGeometrySource(
            data: data.vertexData, semantic: .color, vectorCount: data.pointCount,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 12, dataStride: 24)
        var sources = [positions, colors]
        if let births = data.birthData {
            sources.append(SCNGeometrySource(
                data: births, semantic: .texcoord, vectorCount: data.pointCount,
                usesFloatComponents: true, componentsPerVector: 2,
                bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: 8))
        }
        if cachedPointCount != data.pointCount {
            let element = SCNGeometryElement(data: data.pointIndexData, primitiveType: .point,
                                            primitiveCount: data.pointCount, bytesPerIndex: 4)
            applyPointSize(to: element)
            cachedPointElement = element
            cachedPointCount = data.pointCount
        }
        let points = SCNGeometry(sources: sources, elements: [cachedPointElement!])
        points.materials = [data.birthData == nil ? material : flightMaterial]
        if data.birthData != nil {
            // The GPU moves particles outside the measured bounds while they
            // converge. Expanding only SceneKit's culling box keeps that path
            // visible without changing any measured vertex or framing center.
            let bounds = points.boundingBox
            let margin: Float = 0.025
            points.boundingBox = (
                SCNVector3(bounds.min.x - margin, bounds.min.y - margin, bounds.min.z - margin),
                SCNVector3(bounds.max.x + margin, bounds.max.y + margin, bounds.max.z + margin))
        }
        guard !data.surfaceIndexData.isEmpty else { return (points, points) }
        let triangles = SCNGeometryElement(data: data.surfaceIndexData, primitiveType: .triangles,
                                          primitiveCount: data.surfaceIndexData.count / 12, bytesPerIndex: 4)
        let surface = SCNGeometry(sources: [positions, colors], elements: [triangles])
        surface.materials = [material]
        return (points, surface)
    }

    private static func makeMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.isDoubleSided = true
        return material
    }
}

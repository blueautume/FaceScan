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
    let birthData: Data?
    let animationEndTime: TimeInterval?
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
    private var births: [Cell: Birth] = [:]
    private var endTime: TimeInterval = 0
    private var recordingBirths = false
    private var originalBirths: [Cell: OriginalBirth] = [:]
    private var historyBeforeClear: [Cell: Birth]?
    private var originalEndTime: TimeInterval = 0

    private struct Cell: Hashable {
        let x: Int
        let y: Int
        let z: Int

        init(_ position: SIMD3<Float>) {
            x = Int((position.x / 0.004).rounded())
            y = Int((position.y / 0.004).rounded())
            z = Int((position.z / 0.004).rounded())
        }

        init(x: Int, y: Int, z: Int) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    private struct Birth {
        let position: SIMD3<Float>
        let time: Float
    }

    private struct OriginalBirth {
        let value: Birth?
    }

    func reset() {
        recordingBirths = false
        originalBirths.removeAll(keepingCapacity: true)
        historyBeforeClear = nil
        births.removeAll(keepingCapacity: true)
        endTime = 0
    }

    // A superseded preparation is never shown. Roll its new births back so
    // those particles still receive their full flight on the next visible frame.
    func beginPreparation() {
        precondition(!recordingBirths)
        recordingBirths = true
        originalEndTime = endTime
    }

    func finishPreparation(accepted: Bool) {
        guard recordingBirths else { return }
        if !accepted {
            if let historyBeforeClear {
                births = historyBeforeClear
            } else {
                for (cell, original) in originalBirths { births[cell] = original.value }
            }
            endTime = originalEndTime
        }
        recordingBirths = false
        originalBirths.removeAll(keepingCapacity: true)
        historyBeforeClear = nil
    }

    private func clearBirthHistory() {
        if recordingBirths, historyBeforeClear == nil {
            var original = births
            for (cell, previous) in originalBirths { original[cell] = previous.value }
            historyBeforeClear = original
        }
        births.removeAll(keepingCapacity: true)
    }

    func prepare(vertices: [ScanVertex], triangleIndices: [UInt32] = [],
                 animates: Bool = false, time: TimeInterval = 0) -> PointCloudRenderData {
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
        if births.count > 100_000 { clearBirthHistory() }
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
                let birth = birthTime(for: position, time: time)
                birthValues.append(birth)
                birthValues.append(0)
                endTime = max(endTime, PointCloudAnimationTime.origin + Double(birth) + 0.8)
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
            animationEndTime: animates && pointCount > 0 ? endTime : nil)
    }

    static func isRenderable(_ vertex: ScanVertex) -> Bool {
        let p = vertex.position
        let c = vertex.color
        return p.x.isFinite && p.y.isFinite && p.z.isFinite
            && c.x.isFinite && c.y.isFinite && c.z.isFinite
            && abs(p.x) <= 2 && abs(p.y) <= 2 && abs(p.z) <= 2
            && (0...1).contains(c.x) && (0...1).contains(c.y) && (0...1).contains(c.z)
    }

    private func birthTime(for position: SIMD3<Float>, time: TimeInterval) -> Float {
        let cell = Cell(position)
        var birth = births[cell]?.time
        if birth == nil {
            nearby: for z in -1...1 {
                for y in -1...1 {
                    for x in -1...1 {
                        let neighbor = Cell(x: cell.x + x, y: cell.y + y, z: cell.z + z)
                        if let previous = births[neighbor],
                           simd_distance_squared(previous.position, position) <= 0.000016 {
                            birth = previous.time
                            break nearby
                        }
                    }
                }
            }
        }
        let start = birth ?? PointCloudAnimationTime.shaderTime(at: time)
        if recordingBirths, historyBeforeClear == nil, originalBirths[cell] == nil {
            originalBirths[cell] = OriginalBirth(value: births[cell])
        }
        births[cell] = Birth(position: position, time: start)
        return start
    }
}

/// Only wraps prepared immutable bytes; material and point-element caches are bounded.
@MainActor
final class PointCloudRenderResources {
    private let material: SCNMaterial
    private let flightMaterial: SCNMaterial
    private var cachedPointCount = -1
    private var cachedPointElement: SCNGeometryElement?

    init() {
        material = Self.makeMaterial()
        flightMaterial = Self.makeMaterial()
        flightMaterial.shaderModifiers = [.geometry: PointCloudFlight.shader]
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
            element.pointSize = 0.0014
            element.minimumPointScreenSpaceRadius = 1.4
            element.maximumPointScreenSpaceRadius = 2
            cachedPointElement = element
            cachedPointCount = data.pointCount
        }
        let points = SCNGeometry(sources: sources, elements: [cachedPointElement!])
        points.materials = [data.birthData == nil ? material : flightMaterial]
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

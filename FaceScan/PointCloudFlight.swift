import SceneKit
import UIKit
import simd

/// A bounded display-only animation. Captured positions and exported meshes remain untouched.
@MainActor
final class PointCloudFlight {
    static let duration: TimeInterval = 0.8
    static let distance: Float = 0.14

    private weak var view: SCNView?
    private weak var material: SCNMaterial?
    private let epoch = CACurrentMediaTime()
    private var births: [Cell: Birth] = [:]
    private var endTime: TimeInterval = 0
    private var displayLink: CADisplayLink?
    private var completionTask: Task<Void, Never>?
    private lazy var target = FlightDisplayTarget(flight: self)

    private struct Cell: Hashable {
        let x: Int
        let y: Int
        let z: Int
        init(_ point: SIMD3<Float>) {
            x = Int((point.x / 0.004).rounded())
            y = Int((point.y / 0.004).rounded())
            z = Int((point.z / 0.004).rounded())
        }
        init(x: Int, y: Int, z: Int) { self.x = x; self.y = y; self.z = z }
    }
    private struct Birth {
        let position: SIMD3<Float>
        let time: Float
    }

    init(view: SCNView) { self.view = view }

    func makeGeometry(vertices: [ScanVertex]) -> SCNGeometry? {
        let vertices = vertices.filter(LivePointGeometryBuilder.isRenderable)
        guard let points = LivePointGeometryBuilder.makeGeometry(vertices: vertices) else {
            reset()
            return nil
        }
        let time = now
        var attributes: [Float] = []
        attributes.reserveCapacity(vertices.count * 2)
        // The facial volume normally occupies only a few thousand cells. Keep a hard
        // history bound in case a malformed input moves points throughout the volume.
        if births.count > 100_000 { births.removeAll(keepingCapacity: true) }
        for vertex in vertices {
            let key = Cell(vertex.position)
            var birth = births[key]?.time
            if birth == nil {
                nearby: for z in -1...1 {
                    for y in -1...1 {
                        for x in -1...1 {
                            let neighbor = Cell(x: key.x + x, y: key.y + y, z: key.z + z)
                            if let previous = births[neighbor],
                               simd_distance_squared(previous.position, vertex.position) <= 0.000016 {
                                birth = previous.time
                                break nearby
                            }
                        }
                    }
                }
            }
            let start = birth ?? Float(time)
            births[key] = Birth(position: vertex.position, time: start)
            endTime = max(endTime, Double(start) + Self.duration)
            attributes.append(contentsOf: [start, 0])
        }
        let data = attributes.withUnsafeBytes { Data($0) }
        let times = SCNGeometrySource(data: data, semantic: .texcoord,
            vectorCount: vertices.count, usesFloatComponents: true,
            componentsPerVector: 2, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<Float>.size * 2)
        let geometry = SCNGeometry(sources: points.sources + [times], elements: points.elements)
        geometry.materials = points.materials
        material = geometry.firstMaterial
        material?.shaderModifiers = [.geometry: Self.shader]
        scheduleCompletion()
        tick()
        return geometry
    }

    func finish() {
        completionTask?.cancel()
        completionTask = nil
        displayLink?.invalidate()
        displayLink = nil
        endTime = 0
        material?.setValue(Float(0), forKey: "pointFlightEnabled")
        view?.rendersContinuously = false
        view?.isPlaying = false
        view?.setNeedsDisplay()
    }

    func reset() {
        finish()
        births.removeAll(keepingCapacity: true)
        material = nil
    }

    private var now: TimeInterval { CACurrentMediaTime() - epoch }

    private func scheduleCompletion() {
        completionTask?.cancel()
        let deadline = endTime
        let delay = max(0, deadline - now)
        // Display links may pause for offscreen views. Independently end the
        // effect so a hidden renderer cannot retain a continuous render loop.
        completionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch { return }
            guard !Task.isCancelled, let self, self.endTime == deadline else { return }
            self.finish()
        }
    }

    fileprivate func tick() {
        let time = now
        let active = material != nil && time < endTime
        material?.setValue(Float(time), forKey: "pointFlightTime")
        material?.setValue(Float(active ? 1 : 0), forKey: "pointFlightEnabled")
        view?.rendersContinuously = active
        view?.isPlaying = active
        view?.setNeedsDisplay()
        if active && displayLink == nil {
            let link = CADisplayLink(target: target, selector: #selector(FlightDisplayTarget.tick))
            link.preferredFramesPerSecond = 30
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !active {
            finish()
        }
    }

    // Birth time is a vertex attribute. Each frame updates only two uniforms;
    // X/Y and all rotations stay exactly as supplied by the measured geometry.
    static let shader = """
    #pragma arguments
    float pointFlightTime;
    float pointFlightEnabled;
    #pragma body
    float t = clamp((pointFlightTime - _geometry.texcoords[0].x) / 0.8, 0.0, 1.0);
    float remaining = 1.0 - t;
    _geometry.position.z += 0.14 * remaining * remaining * pointFlightEnabled;
    """
}

@MainActor
private final class FlightDisplayTarget: NSObject {
    weak var flight: PointCloudFlight?
    init(flight: PointCloudFlight) { self.flight = flight }
    @objc func tick() { flight?.tick() }
}

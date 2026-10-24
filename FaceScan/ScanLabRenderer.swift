import SceneKit
import UIKit
import simd

/// Preview-only rendering. Capture/export buffers are never mutated by this renderer.
/// One point geometry and at most two triangle geometries keep the experiment bounded.
@MainActor
final class ScanLabRenderer {
    private let container = SCNNode()
    private let model = SCNNode()
    private let points = SCNNode()
    private let surface = SCNNode()
    private let wireframe = SCNNode()
    private let axes = SCNNode()
    private let bounds = SCNNode()
    private let keyLight = SCNNode()
    private let fillLight = SCNNode()
    private weak var view: SCNView?
    private var settings = ScanLabSettings()
    private var geometryTask: Task<Void, Never>?
    private var pendingSource: PendingSource?
    private var generation = 0
    private var revision: Int?
    private var geometrySignature: GeometrySignature?
    private var processed: ScanLabProcessedGeometry?
    private var replayToken: Int?
    private var acquisition = false
    private var replaying = false
    private var pendingReplay = false
    private var births: [Cell: Birth] = [:]
    private var animationEnd: Double = 0
    private let epoch = CACurrentMediaTime()
    private var displayLink: CADisplayLink?
    private lazy var displayTarget = ScanLabDisplayTarget(renderer: self)
    private var previousTick: Double?
    private var rotation: Float = 0

    private struct PendingSource {
        var vertices: [ScanVertex]
        var triangles: [UInt32]
        var revision: Int
    }

    private struct GeometrySignature: Equatable {
        var filterEnabled: Bool
        var filterMode: ScanLabFilterMode
        var strength: Double
        var radius: Double
        var passes: Int
        var outliers: Bool
        var neighbors: Int
        var needsMesh: Bool
        var edgeLimit: Double
        var stride: Int
        var normals: Bool
        init(_ s: ScanLabSettings) {
            filterEnabled = s.filterEnabled
            filterMode = s.filterMode
            strength = s.filterStrength
            radius = s.filterRadius
            passes = s.filterPasses
            outliers = s.outlierRemovalEnabled
            neighbors = s.outlierMinNeighbors
            needsMesh = s.meshEnabled || s.displayMode != .points || s.colorMode == .normals
            edgeLimit = s.meshEdgeLimit
            stride = s.meshStride
            normals = s.smoothNormals
        }
    }

    private struct Cell: Hashable {
        var x: Int32
        var y: Int32
        var z: Int32
        init(x: Int32, y: Int32, z: Int32) { self.x = x; self.y = y; self.z = z }
        init(_ p: SIMD3<Float>) {
            x = Self.coordinate(p.x)
            y = Self.coordinate(p.y)
            z = Self.coordinate(p.z)
        }
        private static func coordinate(_ value: Float) -> Int32 {
            let scaled = (Double(value) / 0.004).rounded()
            guard scaled.isFinite else { return 0 }
            // Leave one cell of headroom for the adjacent-cell history lookup.
            return Int32(min(Double(Int32.max - 1), max(Double(Int32.min + 1), scaled)))
        }
    }
    private struct Birth {
        var position: SIMD3<Float>
        var time: Float
    }

    init(parent: SCNNode, in view: SCNView) {
        self.view = view
        container.name = "scanLab"
        model.name = "scanLabModel"
        points.name = "scanLabPoints"
        surface.name = "scanLabSurface"
        wireframe.name = "scanLabWireframe"
        axes.name = "scanLabAxes"
        bounds.name = "scanLabBounds"
        parent.addChildNode(container)
        container.addChildNode(model)
        model.addChildNode(points)
        model.addChildNode(surface)
        model.addChildNode(wireframe)
        container.addChildNode(axes)
        model.addChildNode(bounds)
        configureAxes()
        keyLight.light = SCNLight()
        keyLight.light?.type = .directional
        keyLight.eulerAngles = SCNVector3(-0.4, -0.5, 0)
        fillLight.light = SCNLight()
        fillLight.light?.type = .ambient
        fillLight.light?.color = UIColor(red: 0.72, green: 0.80, blue: 1, alpha: 1)
        view.scene?.rootNode.addChildNode(keyLight)
        view.scene?.rootNode.addChildNode(fillLight)
    }

    func update(vertices: [ScanVertex], triangleIndices: [UInt32] = [], revision: Int,
                settings: ScanLabSettings, animatesAcquisition: Bool, replayToken: Int,
                in view: SCNView) {
        self.view = view
        let oldSettings = self.settings
        let newSource = self.revision != revision
        let wantsReplay = self.replayToken != nil && self.replayToken != replayToken
        let stopped = acquisition && !animatesAcquisition
        self.settings = settings
        self.acquisition = animatesAcquisition
        self.replayToken = replayToken
        let signature = GeometrySignature(settings)
        if vertices.isEmpty {
            // Clear synchronously. An old in-flight result must never repopulate
            // the birth history after the user clears or restarts a scan.
            if processed != nil || geometryTask != nil || !births.isEmpty {
                resetSourceHistory()
            }
            self.revision = revision
            geometrySignature = signature
            applyStyle()
            return
        }
        if newSource && self.revision.map({ revision < $0 }) == true {
            resetSourceHistory()
        }
        if animationEnd > now, oldSettings.flyInDuration != settings.flyInDuration {
            animationEnd += settings.flyInDuration - oldSettings.flyInDuration
        }
        if stopped || !settings.flyInEnabled {
            replaying = false
            pendingReplay = false
            animationEnd = 0
        }
        if wantsReplay && settings.flyInEnabled {
            replaying = true
            pendingReplay = true
            births.removeAll(keepingCapacity: true)
        }
        if newSource, !vertices.isEmpty, geometryTask != nil,
           geometrySignature == signature, !wantsReplay {
            // Let an expensive filter finish one useful frame. Keep only the newest
            // incoming snapshot instead of cancelling forever or queuing every frame.
            pendingSource = PendingSource(vertices: vertices, triangles: triangleIndices,
                                          revision: revision)
            self.revision = revision
            applyStyle()
            return
        }
        let needsProcessing = newSource || geometrySignature != signature
            || (processed == nil && geometryTask == nil)
        if needsProcessing {
            self.revision = revision
            geometrySignature = signature
            generation += 1
            let jobGeneration = generation
            geometryTask?.cancel()
            pendingSource = nil
            var processingSettings = settings
            // Modes imply a preview surface; the separate mesh toggle adds wireframe.
            processingSettings.meshEnabled = signature.needsMesh
            processingSettings.pointDensity = 1
            let jobSettings = processingSettings
            geometryTask = Task { [weak self] in
                let job = Task.detached(priority: .userInitiated) {
                    ScanLabGeometryProcessor.process(vertices: vertices,
                        triangleIndices: triangleIndices, settings: jobSettings)
                }
                let result = await withTaskCancellationHandler {
                    await job.value
                } onCancel: {
                    job.cancel()
                }
                guard !Task.isCancelled, let self, self.generation == jobGeneration else { return }
                self.geometryTask = nil
                self.processed = result
                self.uploadGeometry(result, newPointsMayAnimate: newSource || wantsReplay,
                                    replayAll: wantsReplay)
                self.applyStyle()
                if let pending = self.pendingSource, let view = self.view {
                    self.pendingSource = nil
                    self.revision = nil
                    self.update(vertices: pending.vertices, triangleIndices: pending.triangles,
                        revision: pending.revision, settings: self.settings,
                        animatesAcquisition: self.acquisition,
                        replayToken: self.replayToken ?? 0, in: view)
                }
            }
        } else if wantsReplay, let processed {
            uploadGeometry(processed, newPointsMayAnimate: true, replayAll: true)
        } else if oldSettings.pointDensity != settings.pointDensity, let processed {
            // Density only changes the index list; filtering is deliberately not rerun.
            updatePointElement(vertexCount: processed.vertices.count)
        }
        applyStyle()
    }

    private func resetSourceHistory() {
        generation += 1
        geometryTask?.cancel()
        geometryTask = nil
        pendingSource = nil
        processed = nil
        geometrySignature = nil
        births.removeAll(keepingCapacity: true)
        animationEnd = 0
        replaying = false
        pendingReplay = false
        points.geometry = nil
        surface.geometry = nil
        wireframe.geometry = nil
        bounds.geometry = nil
    }

    func stop() {
        generation += 1
        geometryTask?.cancel()
        geometryTask = nil
        pendingSource = nil
        pendingReplay = false
        displayLink?.invalidate()
        displayLink = nil
        previousTick = nil
        container.removeFromParentNode()
        keyLight.removeFromParentNode()
        fillLight.removeFromParentNode()
        view?.rendersContinuously = false
        view?.isPlaying = false
        view = nil
    }

    private var now: Double { CACurrentMediaTime() - epoch }

    private func uploadGeometry(_ result: ScanLabProcessedGeometry,
                                newPointsMayAnimate: Bool, replayAll: Bool) {
        let time = now
        let replayRequested = replayAll || pendingReplay
        let fly = settings.flyInEnabled && (acquisition || replaying || pendingReplay)
        if replayRequested { births.removeAll(keepingCapacity: true) }
        // Source points are in face-local meters. The cell history remembers acquired
        // positions even when the live sampler changes which historical points it shows.
        if births.count > 100_000 { births.removeAll(keepingCapacity: true) }
        var packed: [Float] = []
        packed.reserveCapacity(result.vertices.count * 11)
        var latest = animationEnd
        for (index, vertex) in result.vertices.enumerated() {
            let p = vertex.position
            let key = Cell(p)
            let seed = stableSeed(key)
            var birth = births[key]?.time
            if birth == nil {
                // Also match an adjacent cell, so millimeter fusion drift does not
                // repeatedly re-launch an already observed facial point.
                neighborSearch: for dx in -1...1 {
                    for dy in -1...1 {
                        for dz in -1...1 {
                            let neighbor = Cell(x: key.x + Int32(dx), y: key.y + Int32(dy),
                                                z: key.z + Int32(dz))
                            if let known = births[neighbor], simd_distance_squared(known.position, p) < 0.000016 {
                                birth = known.time
                                break neighborSearch
                            }
                        }
                    }
                }
            }
            let start = birth ?? (fly && (newPointsMayAnimate || replayRequested)
                ? Float(time + Double(seed) * settings.flyInStagger) : -10_000)
            births[key] = Birth(position: p, time: start)
            if start > -1, fly {
                latest = max(latest, Double(start) + settings.flyInDuration)
            }
            let n = index < result.normals.count ? result.normals[index] : SIMD3<Float>(0, 0, 1)
            packed.append(contentsOf: [p.x, p.y, p.z, vertex.color.x, vertex.color.y, vertex.color.z,
                                      n.x, n.y, n.z, start, seed])
        }
        animationEnd = latest
        if pendingReplay { replaying = true }
        pendingReplay = false
        let data = packed.withUnsafeBytes { Data($0) }
        let count = result.vertices.count
        let stride = MemoryLayout<Float>.size * 11
        func source(_ semantic: SCNGeometrySource.Semantic, components: Int, offset: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: data, semantic: semantic, vectorCount: count,
                usesFloatComponents: true, componentsPerVector: components,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: offset * MemoryLayout<Float>.size, dataStride: stride)
        }
        let sources = [source(.vertex, components: 3, offset: 0),
                       source(.color, components: 3, offset: 3),
                       source(.normal, components: 3, offset: 6),
                       source(.texcoord, components: 2, offset: 9)]
        points.geometry = count > 0 ? SCNGeometry(sources: sources, elements: [pointElement(count: count)]) : nil
        if result.triangleIndices.count >= 3 {
            let element = SCNGeometryElement(indices: result.triangleIndices, primitiveType: .triangles)
            surface.geometry = SCNGeometry(sources: sources, elements: [element])
            wireframe.geometry = SCNGeometry(sources: sources, elements: [element])
        } else {
            surface.geometry = nil
            wireframe.geometry = nil
        }
        configureBounds(vertices: result.vertices)
        points.geometry?.materials = [makeMaterial(points: true, wire: false)]
        surface.geometry?.materials = [makeMaterial(points: false, wire: false)]
        wireframe.geometry?.materials = [makeMaterial(points: false, wire: true)]
    }

    private func pointElement(count: Int) -> SCNGeometryElement {
        let density = max(0.02, min(1, settings.pointDensity))
        let outputCount = max(1, Int(Double(count) * density))
        let indices = (0..<outputCount).map { UInt32($0 * count / outputCount) }
        return SCNGeometryElement(indices: indices, primitiveType: .point)
    }

    private func updatePointElement(vertexCount: Int) {
        guard let geometry = points.geometry else { return }
        let replacement = SCNGeometry(sources: geometry.sources, elements: [pointElement(count: vertexCount)])
        replacement.materials = geometry.materials
        points.geometry = replacement
    }

    private func makeMaterial(points: Bool, wire: Bool) -> SCNMaterial {
        let material = SCNMaterial()
        material.name = points ? "labParticles" : wire ? "labWireframe" : "labSurface"
        material.lightingModel = points || wire ? .constant : .physicallyBased
        material.diffuse.contents = UIColor.white
        material.isDoubleSided = true
        material.fillMode = wire ? .lines : .fill
        material.shaderModifiers = [.geometry: Self.geometryShader, .surface: Self.surfaceShader]
        return material
    }

    private func applyStyle() {
        guard let view else { return }
        let mode = settings.displayMode
        points.isHidden = mode == .surface || mode == .wireframe
        surface.isHidden = mode == .points || mode == .wireframe
        wireframe.isHidden = mode != .wireframe && !settings.meshEnabled
        // A sparse live scan may have no usable triangle yet: keep its measurements visible.
        if surface.geometry == nil && wireframe.geometry == nil { points.isHidden = false }
        axes.isHidden = !settings.showAxes
        bounds.isHidden = !settings.showBounds
        view.showsStatistics = settings.showStats
        switch settings.background {
        case .warm: view.backgroundColor = ScanTheme.canvasUIColor
        case .black: view.backgroundColor = .black
        case .midnight: view.backgroundColor = UIColor(red: 0.025, green: 0.045, blue: 0.09, alpha: 1)
        case .light: view.backgroundColor = UIColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1)
        }
        keyLight.light?.intensity = CGFloat(settings.lightIntensity)
        fillLight.light?.intensity = CGFloat(settings.lightIntensity * 0.45)
        if let camera = view.pointOfView?.camera {
            camera.usesOrthographicProjection = settings.orthographic
            camera.orthographicScale = 0.38
            camera.wantsHDR = settings.glow > 0
            camera.wantsExposureAdaptation = false
            camera.bloomIntensity = CGFloat(settings.glow * 1.5)
            camera.bloomThreshold = 0.8
            camera.bloomBlurRadius = 6
        }
        for element in points.geometry?.elements ?? [] {
            element.pointSize = CGFloat(settings.pointSize * 0.0008)
            element.minimumPointScreenSpaceRadius = CGFloat(settings.pointSize * 0.75)
            element.maximumPointScreenSpaceRadius = CGFloat(settings.pointSize)
        }
        for node in [points, surface, wireframe] {
            guard let material = node.geometry?.firstMaterial else { continue }
            let isWire = node === wireframe
            let isSurface = node === surface
            let xray = mode == .xray
            material.transparency = CGFloat(settings.opacity * (isSurface || isWire ? settings.meshOpacity : 1))
                * (xray && isSurface ? 0.55 : 1)
            material.blendMode = settings.additiveBlending || xray ? .add : .alpha
            material.readsFromDepthBuffer = !xray
            material.writesToDepthBuffer = !xray && material.transparency > 0.95
            material.metalness.contents = settings.metalness
            material.roughness.contents = settings.roughness
            material.setValue(Float(Self.colorIndex(settings.colorMode)), forKey: "labColor")
            material.setValue(Float(settings.exposure), forKey: "labExposure")
            material.setValue(Float(settings.saturation), forKey: "labSaturation")
            material.setValue(Float(settings.glow), forKey: "labGlow")
            material.setValue(Float(settings.smoothNormals || !isSurface ? 1 : 0), forKey: "labSmoothNormals")
            material.setValue(Float(settings.flyInDuration), forKey: "labDuration")
            material.setValue(Float(settings.flyInDistance), forKey: "labDistance")
            material.setValue(Float(settings.flyInSpread), forKey: "labSpread")
            material.setValue(Float(settings.flyInSwirl), forKey: "labSwirl")
            material.setValue(Float(settings.pulseEnabled ? settings.pulseAmplitude : 0), forKey: "labPulse")
            material.setValue(Float(settings.pulseSpeed), forKey: "labPulseSpeed")
        }
        if !settings.autoRotate {
            rotation = 0
            model.eulerAngles.y = 0
        }
        tick()
        view.setNeedsDisplay()
    }

    fileprivate func tick() {
        guard let view else { return }
        let time = now
        let elapsed = previousTick.map { min(time - $0, 0.1) } ?? 0
        previousTick = time
        let flies = settings.flyInEnabled && (acquisition || replaying) && time < animationEnd
        if replaying && !flies && !pendingReplay { replaying = false }
        if settings.autoRotate && !acquisition {
            rotation += Float(elapsed * settings.rotationSpeed)
            // The scan is a facial surface. Gentle oscillation preserves its useful side.
            model.eulerAngles.y = sin(rotation) * 0.95
        }
        for node in [points, surface, wireframe] {
            guard let material = node.geometry?.firstMaterial else { continue }
            material.setValue(Float(time), forKey: "labTime")
            material.setValue(Float(flies ? 1 : 0), forKey: "labFly")
        }
        let hasGeometry = points.geometry != nil || surface.geometry != nil || wireframe.geometry != nil
        let active = hasGeometry && (flies || settings.pulseEnabled || (settings.autoRotate && !acquisition))
        view.rendersContinuously = active
        view.isPlaying = active
        if active && displayLink == nil {
            let link = CADisplayLink(target: displayTarget, selector: #selector(ScanLabDisplayTarget.tick))
            link.preferredFramesPerSecond = 30
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !active {
            displayLink?.invalidate()
            displayLink = nil
            previousTick = nil
        }
        view.setNeedsDisplay()
    }

    private static func colorIndex(_ color: ScanLabColorMode) -> Int {
        switch color {
        case .captured: 0
        case .champagne: 1
        case .cyan: 2
        case .depth: 3
        case .height: 4
        case .normals: 5
        }
    }

    private func stableSeed(_ key: Cell) -> Float {
        let hash = UInt32(bitPattern: key.x) &* 73_856_093
            ^ UInt32(bitPattern: key.y) &* 19_349_663
            ^ UInt32(bitPattern: key.z) &* 83_492_791
        return Float(hash % 65_521) / 65_521
    }

    private func configureAxes() {
        let origin = SIMD3<Float>(-0.105, -0.105, 0)
        for (end, color) in [(SIMD3<Float>(0.06, 0, 0), UIColor.systemRed),
                             (SIMD3<Float>(0, 0.06, 0), UIColor.systemGreen),
                             (SIMD3<Float>(0, 0, 0.06), UIColor.systemBlue)] {
            let source = SCNGeometrySource(vertices: [SCNVector3(origin), SCNVector3(origin + end)])
            let geometry = SCNGeometry(sources: [source], elements: [SCNGeometryElement(indices: [UInt32(0), 1], primitiveType: .line)])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color
            geometry.materials = [material]
            axes.addChildNode(SCNNode(geometry: geometry))
        }
    }

    private func configureBounds(vertices: [ScanVertex]) {
        guard let first = vertices.first else { bounds.geometry = nil; return }
        var low = first.position
        var high = first.position
        for vertex in vertices {
            low = simd_min(low, vertex.position)
            high = simd_max(high, vertex.position)
        }
        let corners = [SIMD3(low.x, low.y, low.z), SIMD3(high.x, low.y, low.z),
                       SIMD3(high.x, high.y, low.z), SIMD3(low.x, high.y, low.z),
                       SIMD3(low.x, low.y, high.z), SIMD3(high.x, low.y, high.z),
                       SIMD3(high.x, high.y, high.z), SIMD3(low.x, high.y, high.z)]
        let indices: [UInt32] = [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: corners.map(SCNVector3.init))],
                                  elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(white: 0.7, alpha: 0.5)
        geometry.materials = [material]
        bounds.geometry = geometry
    }

    /// Birth time and a stable seed are vertex attributes. Animation changes only a
    /// handful of uniforms per frame, never thousands of nodes or CPU point positions.
    private static let geometryShader = """
    #pragma arguments
    float labTime;
    float labFly;
    float labDuration;
    float labDistance;
    float labSpread;
    float labSwirl;
    float labPulse;
    float labPulseSpeed;
    float labColor;
    float labExposure;
    float labSaturation;
    #pragma body
    float3 target = _geometry.position.xyz;
    float seed = _geometry.texcoords[0].y;
    float birth = _geometry.texcoords[0].x;
    float t = clamp((labTime - birth) / max(labDuration, 0.05), 0.0, 1.0);
    float remaining = (1.0 - t) * (1.0 - t);
    float angle = seed * 6.283185 + t * labSwirl * 6.283185;
    float3 offset = float3(cos(angle) * labSpread, sin(angle) * labSpread, labDistance);
    _geometry.position.xyz = target + offset * remaining * labFly;
    _geometry.position.xyz += _geometry.normal * labPulse * sin(labTime * labPulseSpeed * 6.283185 + target.y * 35.0);
    float3 color = _geometry.color.rgb;
    if (labColor > 0.5 && labColor < 1.5) color = float3(0.91, 0.72, 0.42);
    if (labColor > 1.5 && labColor < 2.5) color = float3(0.25, 0.84, 1.0);
    if (labColor > 2.5 && labColor < 3.5) {
        float depth = clamp((target.z + 0.08) / 0.16, 0.0, 1.0);
        color = mix(float3(0.15, 0.32, 0.95), float3(1.0, 0.61, 0.22), depth);
    }
    if (labColor > 3.5 && labColor < 4.5) {
        float height = clamp((target.y + 0.12) / 0.28, 0.0, 1.0);
        color = mix(float3(0.48, 0.22, 0.83), float3(0.27, 0.95, 0.77), height);
    }
    if (labColor > 4.5) color = normalize(_geometry.normal) * 0.5 + 0.5;
    float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
    _geometry.color.rgb = clamp(mix(float3(luminance), color, labSaturation) * labExposure, 0.0, 1.0);
    """

    private static let surfaceShader = """
    #pragma arguments
    float labGlow;
    float labSmoothNormals;
    #pragma body
    if (labSmoothNormals < 0.5) {
        _surface.normal = normalize(cross(dfdx(_surface.position), dfdy(_surface.position)));
    }
    _surface.emission.rgb = _surface.diffuse.rgb * labGlow;
    """
}

@MainActor
private final class ScanLabDisplayTarget: NSObject {
    weak var renderer: ScanLabRenderer?
    init(renderer: ScanLabRenderer) { self.renderer = renderer }
    @objc func tick() { renderer?.tick() }
}

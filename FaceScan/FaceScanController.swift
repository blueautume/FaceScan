import ARKit
import AVFoundation
import Combine
import UIKit

enum ScanPhase {
    case idle
    case ready
    case scanning
    case processing
    case complete
    case unavailable
}

/// Owns the capture lifecycle. The delegate and depth reconstruction run on a
/// separate serial queue; only small status values and finished meshes reach UI.
@MainActor
final class FaceScanController: NSObject, ObservableObject {
    @Published var phase: ScanPhase = .idle
    @Published var hint = "准备前置原深感摄像头"
    @Published var progress = ScanProgress(
        acceptedFrames: 0, vertexCount: 0, coveredAngles: [], hint: "请正对镜头"
    )
    @Published var result: ScanMesh?
    @Published var errorMessage: String?
    @Published private(set) var livePointCloud: LivePointCloudSnapshot?

    let session = ARSession()
    let livePose: LiveFacePoseStore

    private let privacyConsent: PrivacyConsentStore
    private let worker: FaceScanWorker
    private var generation = UUID()
    private var isSessionRunning = false
    private var resumeWhenActive = false
    private var isInterrupted = false
    private var isRequestingPermission = false
    private var isViewingFile = false
    private var observers: [NSObjectProtocol] = []
    init(privacyConsent: PrivacyConsentStore) {
        self.privacyConsent = privacyConsent
        let pose = LiveFacePoseStore()
        livePose = pose
        worker = FaceScanWorker(poseStore: pose)
        super.init()
        session.delegate = worker
        session.delegateQueue = worker.queue
        worker.onEvent = { [weak self] event in
            self?.receive(event)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pauseForBackground() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.resumeWhenActive else { return }
                self.resumeWhenActive = false
                self.prepare()
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        session.pause()
    }

    func prepare() {
        guard privacyConsent.isAccepted, !isViewingFile else { return }
        guard phase != .complete, phase != .scanning, phase != .processing else { return }
        guard !isSessionRunning, !isRequestingPermission else { return }
        errorMessage = nil

        // Face tracking may also work on RGB-only hardware. Require a real
        // TrueDepth device separately so this demo never substitutes a fitted mesh.
        guard AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) != nil else {
            unavailable("需要配备前置原深感摄像头的 iPhone。")
            return
        }
        guard ARFaceTrackingConfiguration.isSupported else {
            unavailable("此设备当前不支持 ARKit 人脸追踪。请在支持原深感的 iPhone 真机上运行。")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            runSession()
        case .notDetermined:
            isRequestingPermission = true
            hint = "请允许相机权限，所有扫描数据仅在本机处理"
            let permissionGeneration = generation
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRequestingPermission = false
                    guard self.generation == permissionGeneration,
                          self.privacyConsent.isAccepted, !self.isViewingFile else { return }
                    if allowed {
                        if UIApplication.shared.applicationState == .background {
                            self.resumeWhenActive = true
                        } else {
                            self.runSession()
                        }
                    } else {
                        self.unavailable("未获得相机权限。请前往系统设置，允许本 App 使用相机后重试。")
                    }
                }
            }
        case .denied:
            unavailable("相机权限已关闭。请前往系统设置，允许本 App 使用相机后重试。")
        case .restricted:
            unavailable("相机访问受到系统限制，请检查设备的屏幕使用时间或管理策略。")
        @unknown default:
            unavailable("无法确认相机权限，请检查系统设置后重试。")
        }
    }

    func startScan() {
        guard privacyConsent.isAccepted, !isViewingFile, phase == .ready, isSessionRunning else { return }
        generation = UUID()
        result = nil
        livePointCloud = nil
        errorMessage = nil
        progress = Self.emptyProgress
        phase = .scanning
        hint = "缓慢转头，再轻轻低头、抬头"
        worker.begin(generation: generation)
    }

    func finishScan() {
        guard phase == .scanning else { return }
        phase = .processing
        hint = "正在整理点云…"
        worker.finish(generation: generation)
    }

    /// File viewing never needs the camera. Finish an active scan in place so
    /// opening a document does not silently discard a useful unsaved result.
    func suspendCaptureForFileViewing() {
        isViewingFile = true
        resumeWhenActive = false
        isInterrupted = false
        if phase == .scanning { finishScan() }
        session.pause()
        isSessionRunning = false
        // Invalidate an outstanding camera permission callback without losing
        // a completed scan or an in-flight final reconstruction.
        if phase == .idle || phase == .ready || phase == .unavailable {
            generation = UUID()
            worker.configure(generation: generation)
        }
    }

    func allowCaptureAfterFileViewing() {
        isViewingFile = false
    }

    func reset() {
        isViewingFile = false
        generation = UUID()
        session.pause()
        isSessionRunning = false
        resumeWhenActive = false
        isInterrupted = false
        worker.configure(generation: generation)
        result = nil
        livePointCloud = nil
        errorMessage = nil
        progress = Self.emptyProgress
        phase = .idle
        prepare()
    }

    func stop() {
        generation = UUID()
        resumeWhenActive = false
        isInterrupted = false
        isSessionRunning = false
        session.pause()
        worker.configure(generation: generation)
        result = nil
        livePointCloud = nil
        progress = Self.emptyProgress
        errorMessage = nil
        phase = .idle
        hint = "相机已暂停"
    }

    private func runSession() {
        guard privacyConsent.isAccepted, !isViewingFile else { return }
        guard UIApplication.shared.applicationState != .background else {
            resumeWhenActive = true
            return
        }
        generation = UUID()
        worker.configure(generation: generation)
        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.isLightEstimationEnabled = true
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true
        isInterrupted = false
        phase = .ready
        hint = "将整张脸放入画面，正对镜头后开始扫描"
    }

    private func receive(_ event: FaceScanWorker.Event) {
        // The interruption may end before the main queue consumes its beginning.
        // Its recovery signal can therefore carry the previous generation; only
        // an explicitly pending interruption may consume that signal.
        if case .interruptionEnded = event.payload {
            guard isInterrupted, phase == .ready, !isSessionRunning else { return }
            isInterrupted = false
            prepare()
            return
        }
        guard event.generation == generation else { return }
        switch event.payload {
        case .livePointCloud(let snapshot):
            guard phase == .scanning || phase == .processing else { return }
            livePointCloud = snapshot
        case .guidance(let message):
            guard phase == .ready || phase == .scanning else { return }
            hint = message
        case .progress(let update):
            guard phase == .scanning else { return }
            progress = update
            hint = update.hint
        case .finished(let mesh):
            guard phase == .processing else { return }
            result = mesh
            livePointCloud = LivePointCloudSnapshot(
                revision: mesh.frameCount + 1, vertices: mesh.vertices,
                confirmedPointCount: mesh.vertexCount)
            phase = .complete
            hint = "拖动旋转 · 双指缩放"
            isSessionRunning = false
            isInterrupted = false
            session.pause()
        case .finishRejected(let message):
            guard phase == .processing else { return }
            generation = UUID()
            worker.configure(generation: generation)
            progress = Self.emptyProgress
            livePointCloud = nil
            phase = .ready
            errorMessage = message
            hint = "请正对镜头，重新开始扫描"
        case .restartRequired(let message):
            guard phase == .scanning || phase == .processing else { return }
            generation = UUID()
            worker.configure(generation: generation)
            progress = Self.emptyProgress
            livePointCloud = nil
            phase = .ready
            errorMessage = message
            hint = "请回到正面，重新开始；缓慢转头并保持人脸在画面内"
        case .failed(let message):
            guard phase != .complete else { return }
            unavailable(message)
        case .interrupted:
            guard phase == .ready || phase == .scanning || phase == .processing else { return }
            generation = UUID()
            worker.configure(generation: generation)
            isSessionRunning = false
            isInterrupted = true
            progress = Self.emptyProgress
            livePointCloud = nil
            phase = .ready
            hint = "相机被系统中断，恢复后请重新开始扫描"
        case .interruptionEnded:
            break
        }
    }

    private func unavailable(_ message: String) {
        generation = UUID()
        worker.configure(generation: generation)
        session.pause()
        isSessionRunning = false
        isInterrupted = false
        livePointCloud = nil
        phase = .unavailable
        hint = message
        errorMessage = message
    }

    private func pauseForBackground() {
        guard phase == .ready || phase == .scanning || phase == .processing else { return }
        generation = UUID()
        worker.configure(generation: generation)
        session.pause()
        isSessionRunning = false
        isInterrupted = false
        resumeWhenActive = true
        progress = Self.emptyProgress
        livePointCloud = nil
        phase = .ready
        hint = "扫描因切换到后台而暂停，返回后请重新开始"
    }

    private static var emptyProgress: ScanProgress {
        ScanProgress(acceptedFrames: 0, vertexCount: 0, coveredAngles: [], hint: "请正对镜头")
    }
}

/// All mutable fields below, including DepthReconstructor, belong to `queue`.
/// Using the ARSession delegate queue directly avoids retaining a backlog of
/// full-resolution ARFrames in additional asynchronous work items.
private final class FaceScanWorker: NSObject, ARSessionDelegate {
    static let minimumFrameCount = 2
    let queue = DispatchQueue(label: "FaceScan.depth-reconstruction", qos: .userInitiated)
    var onEvent: (@MainActor (Event) -> Void)?
    private let poseStore: LiveFacePoseStore

    init(poseStore: LiveFacePoseStore) {
        self.poseStore = poseStore
        super.init()
    }

    struct Event {
        let generation: UUID
        let payload: Payload
    }

    enum Payload {
        case livePointCloud(LivePointCloudSnapshot)
        case guidance(String)
        case progress(ScanProgress)
        case finished(ScanMesh)
        case finishRejected(String)
        case restartRequired(String)
        case failed(String)
        case interrupted
        case interruptionEnded
    }

    private lazy var reconstructor = DepthReconstructor()
    private var generation = UUID()
    private var collecting = false
    private var lastProcessedTimestamp: TimeInterval = -.infinity
    private var lastDepthTimestamp: TimeInterval = -.infinity
    private var lastGuidanceTimestamp: TimeInterval = -.infinity
    private var lastPreviewTimestamp: TimeInterval = -.infinity
    private var lastPreviewAcceptedFrames = 0
    private var previewDeliveryPending = false
    private var lastProgress = ScanProgress(
        acceptedFrames: 0, vertexCount: 0, coveredAngles: [], hint: "请正对镜头"
    )

    func configure(generation: UUID) {
        queue.async { [self] in
            self.generation = generation
            collecting = false
            clearCapture()
        }
    }

    func begin(generation: UUID) {
        queue.async { [self] in
            self.generation = generation
            clearCapture()
            collecting = true
        }
    }

    func finish(generation: UUID) {
        queue.async { [self] in
            guard generation == self.generation, collecting else { return }
            collecting = false
            guard lastProgress.acceptedFrames >= Self.minimumFrameCount else {
                emit(.finishRejected("有效深度不足，请正对镜头保持片刻后重新扫描。"))
                return
            }
            guard let mesh = reconstructor.makeMesh(),
                  mesh.vertices.count >= 100,
                  mesh.triangleIndices.count.isMultiple(of: 3),
                  mesh.vertices.allSatisfy({
                      $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite
                  }),
                  mesh.triangleIndices.allSatisfy({ Int($0) < mesh.vertices.count }) else {
                emit(.finishRejected("有效点云不足，请保持自然表情和适当距离后重新扫描。"))
                return
            }
            collecting = false
            emit(.finished(mesh))
            reconstructor.reset()
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Pose follows camera frames independently of the 8 Hz depth fusion.
        if collecting, let face = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked {
            poseStore.update(faceToCamera: frame.camera.viewMatrix(for: .portrait) * face.transform)
        }
        guard frame.timestamp - lastProcessedTimestamp >= 0.12 else { return }
        // Face tracking does not require world tracking. ARCamera's position-
        // tracking state is not a valid substitute for ARFaceAnchor.isTracked.
        guard let face = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first,
              face.isTracked else {
            guidance("未检测到稳定人脸，请让整张脸进入画面并改善光线", timestamp: frame.timestamp)
            return
        }
        guard frame.capturedDepthData != nil else {
            guidance("等待原深感深度数据，请保持正对镜头；持续无数据时请重新扫描", timestamp: frame.timestamp)
            return
        }
        let depthTimestamp = frame.capturedDepthDataTimestamp
        guard depthTimestamp > lastDepthTimestamp,
              abs(frame.timestamp - depthTimestamp) <= 0.15 else {
            guidance("等待同步的彩色与深度画面，请保持手机稳定", timestamp: frame.timestamp)
            return
        }
        lastProcessedTimestamp = frame.timestamp
        lastDepthTimestamp = depthTimestamp
        guard collecting else {
            guidance("已检测到人脸与真实深度，可开始扫描", timestamp: frame.timestamp)
            return
        }
        lastProgress = reconstructor.integrate(frame: frame, face: face)
        if lastProgress.requiresRestart {
            collecting = false
            emit(.restartRequired("人脸追踪已切换，本轮已重置，避免把不同坐标的面部混在一起。请回正并重新开始。"))
            return
        }
        emit(.progress(lastProgress))
        // The preview samples fused points only: no makeMesh(), normals, or
        // triangle traversal on the live path. One in-flight snapshot at most.
        if !previewDeliveryPending,
           lastProgress.acceptedFrames > lastPreviewAcceptedFrames,
           frame.timestamp - lastPreviewTimestamp >= 0.25 {
            lastPreviewTimestamp = frame.timestamp
            if let snapshot = reconstructor.makePointCloudSnapshot() {
                lastPreviewAcceptedFrames = lastProgress.acceptedFrames
                emitPreview(snapshot)
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        collecting = false
        emit(.failed("原深感采集失败：\(error.localizedDescription)。请确认相机未被其他 App 占用，再重试。"))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        collecting = false
        emit(.interrupted)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        emit(.interruptionEnded)
    }

    private func clearCapture() {
        poseStore.reset()
        reconstructor.reset()
        lastProcessedTimestamp = -.infinity
        lastDepthTimestamp = -.infinity
        lastGuidanceTimestamp = -.infinity
        lastPreviewTimestamp = -.infinity
        lastPreviewAcceptedFrames = 0
        previewDeliveryPending = false
        lastProgress = ScanProgress(
            acceptedFrames: 0, vertexCount: 0, coveredAngles: [], hint: "请正对镜头"
        )
    }

    private func guidance(_ message: String, timestamp: TimeInterval) {
        guard timestamp - lastGuidanceTimestamp >= 0.6 else { return }
        lastGuidanceTimestamp = timestamp
        emit(.guidance(message))
    }

    private func emit(_ payload: Payload) {
        let event = Event(generation: generation, payload: payload)
        let callback = onEvent
        DispatchQueue.main.async {
            callback?(event)
        }
    }

    private func emitPreview(_ snapshot: LivePointCloudSnapshot) {
        previewDeliveryPending = true
        let token = generation
        let event = Event(generation: token, payload: .livePointCloud(snapshot))
        let callback = onEvent
        DispatchQueue.main.async { [weak self] in
            callback?(event)
            self?.queue.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.previewDeliveryPending = false
            }
        }
    }
}

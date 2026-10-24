import ARKit
import SwiftUI

struct ContentView: View {
    @StateObject private var privacy: PrivacyConsentStore
    @StateObject private var scanner: FaceScanController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsPrivacy = false
    @State private var exporting = false
    @State private var exportTask: Task<URL, Error>?
    @State private var exportError: String?
    @State private var exportGeneration = UUID()
    @State private var savedNotice = false
    @State private var exportURL: URL?
    @State private var errorTitle = "无法导出"
    @State private var hasEnteredCapture = false
    @State private var wantsToScan = false
    @State private var choosingFile = false
    @State private var pickerGeneration = UUID()
    @State private var openingFile = false
    @State private var importedDocument: PLYDocument?
    @State private var viewerID = UUID()
    @State private var importGeneration = UUID()
    @State private var importTask: Task<Void, Never>?
    @State private var finalSnapshot: LivePointCloudSnapshot?
    // Explicit launch fixtures are available to developers, without production demo controls.
    @State private var sampleMesh: ScanMesh?
    @State private var syntheticSnapshot: LivePointCloudSnapshot?
    @State private var showsLiveSample = false

    init() {
        let consent = PrivacyConsentStore()
        _privacy = StateObject(wrappedValue: consent)
        _scanner = StateObject(wrappedValue: FaceScanController(privacyConsent: consent))
    }

    private var mesh: ScanMesh? { sampleMesh ?? scanner.result }
    private var isScanning: Bool { scanner.phase == .scanning || scanner.phase == .processing }
    private var showsPoints: Bool { isScanning || mesh != nil || showsLiveSample }
    private var snapshot: LivePointCloudSnapshot? {
        if showsLiveSample { return syntheticSnapshot }
        return finalSnapshot ?? scanner.livePointCloud
    }
    private var usesCaptureCanvas: Bool {
        !openingFile && (importedDocument != nil || showsPoints
            || privacy.isAccepted && hasEnteredCapture && scanner.phase != .unavailable)
    }

    var body: some View {
        let pickerToken = pickerGeneration
        VStack(spacing: 20) {
            HStack {
                Text(importedDocument?.filename ?? "FaceScan")
                    .font(.system(size: 21, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    wantsToScan = false
                    scanner.suspendCaptureForFileViewing()
                    pickerGeneration = UUID()
                    choosingFile = true
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 17))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(ScanTheme.secondary)
                }
                .disabled(exporting || openingFile)
                .accessibilityLabel("打开 PLY 文件")
                Button {
                    showsPrivacy = true
                } label: {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 17, weight: .regular))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(ScanTheme.secondary)
                }
                .accessibilityLabel("隐私协议")
            }

            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            controls
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ScanTheme.background)
        .foregroundStyle(ScanTheme.primary)
        .tint(ScanTheme.tint)
        .overlay {
            if showsPrivacy {
                ZStack {
                    ScanTheme.scrim.ignoresSafeArea()
                    PrivacyPolicyView(
                        isAccepted: privacy.isAccepted,
                        onAccept: {
                            privacy.accept()
                            showsPrivacy = false
                            prepareCapture()
                        },
                        onLater: { showsPrivacy = false },
                        onRevoke: revokeConsent)
                    .padding(20)
                    .frame(maxWidth: 560)
                }
                .accessibilityAddTraits(.isModal)
            }
        }
        .onAppear {
            ScanExporter.removeTemporaryExports()
            if privacy.isAccepted { prepareCapture() }
            else { showsPrivacy = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, privacy.isAccepted, hasEnteredCapture,
               mesh == nil, importedDocument == nil, !openingFile,
               !choosingFile, !showsLiveSample {
                scanner.prepare()
            }
        }
        .onChange(of: scanner.phase) { _, phase in
            if phase == .ready, wantsToScan, !openingFile, importedDocument == nil {
                wantsToScan = false
                scanner.startScan()
            } else if phase == .unavailable {
                wantsToScan = false
            }
        }
        .onOpenURL { url in openFile(url) }
        .fileImporter(isPresented: $choosingFile,
                      allowedContentTypes: [PLYFileType.type], allowsMultipleSelection: false) { result in
            guard pickerToken == pickerGeneration else { return }
            switch result {
            case .success(let urls):
                if let url = urls.first { openFile(url) }
                else { restoreCapture() }
            case .failure(let error):
                errorTitle = "无法打开 PLY"
                exportError = error.localizedDescription
                restoreCapture()
            }
        }
        .onChange(of: choosingFile) { _, presented in
            if !presented, !openingFile, importedDocument == nil { restoreCapture() }
        }
        .sheet(isPresented: Binding(
            get: { exportURL != nil }, set: { if !$0 { clearStagedExport() } }
        ), onDismiss: clearStagedExport) {
            if let exportURL {
                DocumentExportPicker(url: exportURL) { saved in
                    savedNotice = saved && privacy.isAccepted
                    clearStagedExport()
                }
                .ignoresSafeArea()
            }
        }
        .task(id: showsLiveSample) {
            guard showsLiveSample else { return }
            let points = SampleFaceMesh.make().vertices.sorted { abs($0.position.x) < abs($1.position.x) }
            for revision in 1...40 {
                guard !Task.isCancelled else { return }
                let count = points.count * revision / 40
                syntheticSnapshot = LivePointCloudSnapshot(
                    revision: revision, vertices: Array(points.prefix(count)),
                    confirmedPointCount: count, isSample: true)
                try? await Task.sleep(for: .milliseconds(180))
            }
        }
        .alert(errorTitle, isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("好", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "请重试。") }
    }

    private var stage: some View {
        ZStack {
            // One stable pair of native views for preparation, live capture and the result.
            ScanPreviewSurface(
                session: scanner.session, snapshot: snapshot,
                showsPointCloud: showsPoints, hasLiveStage: showsPoints,
                showsCamera: privacy.isAccepted && !showsPrivacy && mesh == nil
                    && hasEnteredCapture && importedDocument == nil && !openingFile
                    && !showsLiveSample && scanner.phase != .unavailable,
                poseStore: scanner.livePose,
                followsFacePose: scanner.phase == .scanning)
                .opacity(importedDocument == nil && !openingFile ? 1 : 0)
                .allowsHitTesting(importedDocument == nil && !openingFile)
                .accessibilityHidden(importedDocument != nil || openingFile)

            if let document = importedDocument {
                PLYViewerView(id: viewerID, mesh: document.mesh)
                    .allowsHitTesting(!openingFile)
            } else if !privacy.isAccepted || scanner.phase == .unavailable || !hasEnteredCapture && !showsPoints {
                ScanTheme.surface
                Image(systemName: privacy.isAccepted ? "faceid" : "hand.raised")
                    .font(.system(size: 58, weight: .ultraLight))
                    .foregroundStyle(ScanTheme.tint.opacity(0.55))
                    .accessibilityHidden(true)
            } else if !showsPoints {
                GeometryReader { geometry in
                    Ellipse()
                        .stroke(ScanTheme.canvasAccent.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [6, 8]))
                        .frame(width: geometry.size.width * 0.78, height: min(geometry.size.height * 0.78, geometry.size.width * 1.16))
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                .allowsHitTesting(false)
            } else if snapshot == nil {
                ProgressView("正在建立点云")
                    .font(.system(size: 13))
                    .tint(ScanTheme.canvasAccent)
                    .foregroundStyle(ScanTheme.canvasText)
            }

            if openingFile {
                ScanTheme.surface
                ProgressView("正在打开 PLY…")
                    .font(.system(size: 13))
                    .foregroundStyle(ScanTheme.secondary)
            }

            VStack {
                HStack(spacing: 7) {
                    if importedDocument == nil, !openingFile, isScanning || showsLiveSample {
                        Circle().fill(ScanTheme.canvasAccent).frame(width: 5, height: 5)
                    }
                    Text(stageLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(usesCaptureCanvas ? ScanTheme.canvasAccent : ScanTheme.tint)
                    Spacer()
                }
                Spacer()
                if isScanning, importedDocument == nil, !openingFile {
                    HStack(spacing: 5) {
                        ForEach(ScanAngle.allCases, id: \.self) { angle in
                            Capsule()
                                .fill(scanner.progress.coveredAngles.contains(angle)
                                      ? ScanTheme.canvasAccent : ScanTheme.canvasTrack)
                                .frame(height: 3)
                        }
                    }
                    .accessibilityLabel("已覆盖 \(scanner.progress.coveredAngles.count) 个视角，共 7 个")
                    .padding(.horizontal, 26)
                    .padding(.bottom, 12)
                }
                if !openingFile, privacy.isAccepted || importedDocument != nil {
                    Text(stageHint)
                        .font(.system(size: 12, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(usesCaptureCanvas ? ScanTheme.canvasText : ScanTheme.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(usesCaptureCanvas ? ScanTheme.canvasOverlay : ScanTheme.card.opacity(0.8), in: Capsule())
                }
            }
            .padding(18)
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .stroke(usesCaptureCanvas ? ScanTheme.canvasTrack : ScanTheme.border.opacity(0.7))
                .allowsHitTesting(false)
        }
        .accessibilityHidden(showsPrivacy)
    }

    private var stageLabel: String {
        if openingFile { return "" }
        if let importedDocument {
            return importedDocument.mesh.isSample ? "合成示例 · PLY 点云" : "PLY 点云"
        }
        if sampleMesh != nil || showsLiveSample { return "合成示例 · 非真实扫描" }
        if mesh != nil { return "扫描完成" }
        if isScanning { return "实时点云" }
        return ""
    }

    private var stageHint: String {
        if importedDocument != nil { return "拖动旋转 · 双指缩放" }
        if mesh != nil { return savedNotice ? "已导出" : "拖动旋转 · 双指缩放" }
        if !hasEnteredCapture { return "点按开始扫描，或打开 PLY 文件" }
        if showsLiveSample { return "合成点云演示" }
        if scanner.phase == .ready, scanner.errorMessage == nil { return "正对镜头 · 距离约 30–50 厘米" }
        return scanner.errorMessage ?? scanner.hint
    }

    @ViewBuilder
    private var controls: some View {
        if openingFile {
            primaryButton("取消打开", symbol: "xmark") { cancelOpeningFile() }
        } else if importedDocument != nil {
            primaryButton("关闭文件", symbol: "xmark") { closeFile() }
        } else if !privacy.isAccepted {
            primaryButton("查看隐私协议", symbol: "hand.raised") { showsPrivacy = true }
        } else if let mesh {
            VStack(spacing: 10) {
                primaryButton(exporting ? "正在导出…" : "导出 PLY", symbol: "square.and.arrow.up") {
                    export(mesh)
                }
                .disabled(exporting)
                Button("重新扫描", action: restart)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ScanTheme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .disabled(exporting)
            }
        } else if showsLiveSample {
            primaryButton("结束演示", symbol: "stop.fill") { restart() }
        } else if scanner.phase == .scanning {
            primaryButton("停止扫描", symbol: "stop.fill") { scanner.finishScan() }
        } else if scanner.phase == .processing {
            ProgressView("正在整理点云…")
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, minHeight: 56)
        } else {
            primaryButton(wantsToScan ? "正在准备…" : (scanner.phase == .unavailable ? "重试" : "开始扫描"),
                          symbol: "viewfinder", action: beginScan)
                .disabled(wantsToScan)
        }
    }

    private func primaryButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(ScanPrimaryButton())
    }

    private func prepareCapture() {
        guard privacy.isAccepted, importedDocument == nil, !openingFile else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--sample") {
            let sample = SampleFaceMesh.make()
            sampleMesh = sample
            finalSnapshot = LivePointCloudSnapshot(revision: 1, vertices: sample.vertices,
                                                   confirmedPointCount: sample.vertexCount, isSample: true)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--live-sample") {
            showsLiveSample = true
            return
        }
        #endif
        // A document launch must never activate the camera. Capture starts
        // only after the user explicitly requests scanning.
        if hasEnteredCapture { scanner.prepare() }
    }

    private func beginScan() {
        guard privacy.isAccepted else { showsPrivacy = true; return }
        hasEnteredCapture = true
        wantsToScan = true
        scanner.allowCaptureAfterFileViewing()
        scanner.prepare()
        if scanner.phase == .ready {
            wantsToScan = false
            scanner.startScan()
        } else if scanner.phase == .unavailable {
            wantsToScan = false
        }
    }

    private func restart() {
        hasEnteredCapture = true
        wantsToScan = false
        sampleMesh = nil
        finalSnapshot = nil
        syntheticSnapshot = nil
        showsLiveSample = false
        savedNotice = false
        scanner.reset()
    }

    private func revokeConsent() {
        privacy.revoke()
        scanner.stop()
        cancelExport()
        importGeneration = UUID()
        importTask?.cancel()
        importTask = nil
        importedDocument = nil
        openingFile = false
        pickerGeneration = UUID()
        choosingFile = false
        wantsToScan = false
        hasEnteredCapture = false
        ScanExporter.removeTemporaryExports()
        sampleMesh = nil
        finalSnapshot = nil
        syntheticSnapshot = nil
        showsLiveSample = false
        savedNotice = false
        showsPrivacy = false
    }

    private func export(_ mesh: ScanMesh) {
        guard !exporting, privacy.isAccepted else { return }
        exporting = true
        savedNotice = false
        let token = UUID()
        exportGeneration = token
        let task = Task.detached(priority: .userInitiated) {
            try ScanExporter.export(mesh)
        }
        exportTask = task
        Task {
            do {
                let url = try await task.value
                if privacy.isAccepted, token == exportGeneration { exportURL = url }
                else { try? FileManager.default.removeItem(at: url) }
            } catch {
                if token == exportGeneration {
                    errorTitle = "无法导出"
                    exportError = error.localizedDescription
                }
            }
            if token == exportGeneration {
                exporting = false
                exportTask = nil
            }
        }
    }

    private func clearStagedExport() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
        exportURL = nil
    }

    private func cancelExport() {
        exportGeneration = UUID()
        exportTask?.cancel()
        exportTask = nil
        exporting = false
        clearStagedExport()
    }

    private func openFile(_ url: URL) {
        pickerGeneration = UUID()
        choosingFile = false
        wantsToScan = false
        scanner.suspendCaptureForFileViewing()
        cancelExport()
        importTask?.cancel()
        let token = UUID()
        importGeneration = token
        openingFile = true
        savedNotice = false
        importTask = Task {
            do {
                let document = try await PLYImporter.load(from: url)
                guard !Task.isCancelled, importGeneration == token else { return }
                viewerID = token
                importedDocument = document
                openingFile = false
                importTask = nil
            } catch {
                guard !Task.isCancelled, importGeneration == token else { return }
                openingFile = false
                importTask = nil
                errorTitle = "无法打开 PLY"
                exportError = error.localizedDescription
                if importedDocument == nil { restoreCapture() }
            }
        }
    }

    private func cancelOpeningFile() {
        importGeneration = UUID()
        importTask?.cancel()
        importTask = nil
        openingFile = false
        if importedDocument == nil { restoreCapture() }
    }

    private func closeFile() {
        importedDocument = nil
        restoreCapture()
    }

    private func restoreCapture() {
        guard importedDocument == nil, !openingFile else { return }
        scanner.allowCaptureAfterFileViewing()
        if hasEnteredCapture, privacy.isAccepted { scanner.prepare() }
    }

}

struct ScanPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ScanTheme.primary)
            .background(configuration.isPressed ? ScanTheme.accentPressed : ScanTheme.accent,
                        in: RoundedRectangle(cornerRadius: 18))
    }
}


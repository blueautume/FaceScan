import ARKit
import SwiftUI

struct ContentView: View {
    @StateObject private var privacy: PrivacyConsentStore
    @StateObject private var scanner: FaceScanController
    @StateObject private var history: ScanHistoryStore
    @StateObject private var scanFilter = ScanFilterController()
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
    @State private var openingHistory = false
    @State private var showsHistory = false
    @State private var historicalMesh: ScanMesh?
    @State private var historicalEntry: ScanHistoryEntry?
    @State private var importedDocument: PLYDocument?
    @State private var viewerID = UUID()
    @State private var importGeneration = UUID()
    @State private var importTask: Task<Void, Never>?
    @State private var finalSnapshot: LivePointCloudSnapshot?
    // Explicit launch fixtures are available to developers, without production demo controls.
    @State private var sampleMesh: ScanMesh?
    @State private var syntheticSnapshot: LivePointCloudSnapshot?
    @State private var showsLiveSample = false
    @State private var resultPointSizeScale = 1.0
    @State private var filterSettings = ScanFilterSettings.load()
    @State private var showsFilterSettings = false
    #if DEBUG
    @State private var hasSeededHistoryPreview = false
    #endif

    init() {
        let consent = PrivacyConsentStore()
        let historyStore = ScanHistoryStore()
        _privacy = StateObject(wrappedValue: consent)
        _history = StateObject(wrappedValue: historyStore)
        _scanner = StateObject(wrappedValue: FaceScanController(privacyConsent: consent) {
            historyStore.recordCompletedScan($0)
        })
    }

    private var originalMesh: ScanMesh? { historicalMesh ?? sampleMesh ?? scanner.result }
    private var mesh: ScanMesh? { originalMesh.map { scanFilter.displayedMesh(for: $0) } }
    private var filteredResult: ScanFilterResult? { originalMesh.flatMap { scanFilter.result(for: $0) } }
    private var activePointSizeScale: Double {
        mesh == nil || showsLiveSample ? 1 : resultPointSizeScale
    }
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
        errorPresentation
    }

    private var layout: some View {
        VStack(spacing: 12) {
            HStack {
                Text(importedDocument?.filename ?? "FaceScan")
                    .font(.system(size: 21, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(action: openHistoryList) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 17))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(ScanTheme.secondary)
                }
                .overlay(alignment: .topTrailing) {
                    if history.hasFailedSaves {
                        Circle().fill(ScanTheme.destructive).frame(width: 7, height: 7)
                            .padding(7)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(exporting || openingFile)
                .accessibilityLabel("扫描历史")
                .accessibilityIdentifier("history.open")
                Button {
                    wantsToScan = false
                    scanFilter.cancel()
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
                            history.refresh()
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
    }

    private var lifecycle: some View {
        let pickerToken = pickerGeneration
        return layout
        .onAppear {
            ScanExporter.removeTemporaryExports()
            if privacy.isAccepted { history.refresh(); prepareCapture() }
            else { showsPrivacy = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, privacy.isAccepted, hasEnteredCapture,
               mesh == nil, importedDocument == nil, !openingFile,
               !choosingFile, !showsHistory, historicalMesh == nil, !showsLiveSample {
                scanner.prepare()
            }
        }
        .onChange(of: scanner.phase) { _, phase in
            if phase == .ready, wantsToScan, !openingFile, !showsHistory,
               historicalMesh == nil, importedDocument == nil {
                wantsToScan = false
                scanner.startScan()
            } else if phase == .unavailable {
                wantsToScan = false
            }
        }
        .onChange(of: scanFilter.showsFiltered) { _, _ in savedNotice = false }
        .onChange(of: scanFilter.result?.mesh.renderIdentity) { _, _ in savedNotice = false }
        .onChange(of: originalMesh?.renderIdentity) { _, _ in resultPointSizeScale = 1 }
        .onChange(of: filterSettings) { _, settings in settings.save() }
        .onChange(of: showsHistory) { _, presented in
            if !presented, !openingFile { restoreCapture() }
        }
        .onChange(of: history.entries) { _, entries in
            if let historicalEntry, !entries.contains(where: { $0.id == historicalEntry.id }) {
                closeHistory()
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
    }

    private var sheets: some View {
        lifecycle
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
        .sheet(isPresented: $showsFilterSettings) {
            ScanFilterSettingsView(settings: $filterSettings) {
                showsFilterSettings = false
                applyFilter()
            }
        }
        .sheet(isPresented: $showsHistory) {
            ScanHistoryView(history: history, onOpen: openHistory)
        }
    }

    private var errorPresentation: some View {
        sheets
        .task(id: showsLiveSample) {
            await animateLiveSample()
        }
        .alert(activeErrorTitle, isPresented: Binding(
            get: { activeErrorMessage != nil },
            set: { if !$0 { clearErrors() } }
        )) {
            if activeErrorTitle == "历史记录", history.hasFailedSaves {
                Button("重试保存") { history.retryFailedSaves(); clearErrors() }
            }
            Button("好", role: .cancel) { clearErrors() }
        } message: { Text(activeErrorMessage ?? "请重试。") }
    }

    private var activeErrorTitle: String {
        if scanFilter.errorMessage != nil { return "无法滤波" }
        if exportError == nil, history.errorMessage != nil, !showsHistory { return "历史记录" }
        return errorTitle
    }

    private var activeErrorMessage: String? {
        scanFilter.errorMessage ?? exportError
            ?? (showsHistory ? nil : history.errorMessage)
    }

    private var stage: some View {
        ZStack {
            // One stable pair of native views for preparation, live capture and the result.
            ScanPreviewSurface(
                session: scanner.session, snapshot: snapshot,
                showsPointCloud: showsPoints, hasLiveStage: showsPoints,
                showsCamera: privacy.isAccepted && !showsPrivacy && mesh == nil
                    && hasEnteredCapture && importedDocument == nil && !openingFile && !showsHistory
                    && !showsLiveSample && scanner.phase != .unavailable,
                poseStore: scanner.livePose,
                followsFacePose: scanner.phase == .scanning,
                surfaceMesh: mesh,
                resultFramingIdentity: originalMesh?.renderIdentity,
                displayStyle: .points,
                animatesAcquisition: scanner.phase == .scanning || showsLiveSample,
                pointSizeScale: activePointSizeScale)
                .opacity(importedDocument == nil && !openingFile ? 1 : 0)
                .allowsHitTesting(importedDocument == nil && !openingFile)
                .accessibilityHidden(importedDocument != nil || openingFile)

            if let document = importedDocument {
                PLYViewerView(id: viewerID, mesh: document.mesh)
                    .allowsHitTesting(!openingFile)
            } else if !privacy.isAccepted || scanner.phase == .unavailable && mesh == nil
                || !hasEnteredCapture && !showsPoints {
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
            } else if snapshot == nil, mesh == nil {
                ProgressView("正在建立点云")
                    .font(.system(size: 13))
                    .tint(ScanTheme.canvasAccent)
                    .foregroundStyle(ScanTheme.canvasText)
            }

            if openingFile {
                ScanTheme.surface
                ProgressView(openingHistory ? "正在打开历史…" : "正在打开 PLY…")
                    .font(.system(size: 13))
                    .foregroundStyle(ScanTheme.secondary)
            }

            VStack {
                HStack(spacing: 7) {
                    if importedDocument == nil, historicalMesh == nil, !openingFile, isScanning || showsLiveSample {
                        Circle().fill(ScanTheme.canvasAccent).frame(width: 5, height: 5)
                    }
                    Text(stageLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(usesCaptureCanvas ? ScanTheme.canvasAccent : ScanTheme.tint)
                    Spacer()
                }
                Spacer()
                if !openingFile, mesh == nil, !isScanning, !showsLiveSample,
                   privacy.isAccepted || importedDocument != nil {
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
        .overlay(alignment: .bottomTrailing) {
            if filteredResult != nil, importedDocument == nil, !openingFile, !showsHistory {
                ScanResultComparisonButton(isFiltered: mesh?.isFiltered == true) {
                    scanFilter.showsFiltered.toggle()
                }
                .disabled(exporting)
                .padding(16)
            }
        }
        .accessibilityHidden(showsPrivacy)
    }

    private var stageLabel: String {
        if openingFile { return "" }
        if let importedDocument {
            return importedDocument.mesh.isSample ? "合成示例 · PLY 点云" : "PLY 点云"
        }
        if originalMesh?.isSample == true || showsLiveSample { return "合成示例 · 非真实扫描" }
        if isScanning { return "实时点云" }
        return ""
    }

    private var stageHint: String {
        if importedDocument != nil { return "拖动旋转 · 双指缩放 · 双击重置" }
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
                ScanPointSizeControl(title: "点大小", scale: $resultPointSizeScale)
                    .frame(minHeight: 38)

                Button {
                    showsFilterSettings = true
                } label: {
                    HStack(spacing: 8) {
                        Label("滤波参数", systemImage: "slider.horizontal.3")
                        Spacer(minLength: 8)
                        Text(filterSettings.presetName)
                            .foregroundStyle(ScanTheme.secondary)
                        if let filteredResult, filteredResult.settings != filterSettings {
                            Circle().fill(ScanTheme.tint).frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ScanTheme.secondary)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(ScanTheme.card, in: RoundedRectangle(cornerRadius: 13))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(exporting || scanFilter.isFiltering)
                .accessibilityIdentifier("filter.settings")
                .accessibilityValue(filterSettings.presetName)
                .accessibilityHint(filteredResult.map { $0.settings != filterSettings } == true
                                   ? "参数已更改，下次滤波时应用" : "调整滤波参数")

                HStack(spacing: 12) {
                    ScanFilterActionButton(isFiltering: scanFilter.isFiltering,
                                           progress: scanFilter.progress,
                                           onApply: applyFilter, onCancel: scanFilter.cancel)
                        .disabled(exporting)
                    primaryButton(exporting ? "导出中…" : (savedNotice ? "已导出" : "导出"),
                                  symbol: savedNotice ? "checkmark" : "square.and.arrow.up") {
                        export(mesh)
                    }
                    .disabled(exporting || scanFilter.isFiltering)
                    .accessibilityIdentifier("scan.export")
                    .accessibilityHint(mesh.isFiltered ? "导出当前滤波点云为 PLY" : "导出当前原始点云为 PLY")
                }

                Button("重新扫描", action: restart)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ScanTheme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(exporting)
                    .accessibilityIdentifier("scan.restart")
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

    private func animateLiveSample() async {
        guard showsLiveSample else { return }
        let sample = SampleFaceMesh.make()
        let points: [ScanVertex] = sample.vertices.sorted { (left: ScanVertex, right: ScanVertex) -> Bool in
            Swift.abs(left.position.x) < Swift.abs(right.position.x)
        }
        for revision in 1...40 {
            guard !Task.isCancelled else { return }
            let count = points.count * revision / 40
            syntheticSnapshot = LivePointCloudSnapshot(
                revision: revision, vertices: Array(points.prefix(count)),
                confirmedPointCount: count, isSample: true)
            try? await Task.sleep(for: .milliseconds(180))
        }
    }

    private func prepareCapture() {
        guard privacy.isAccepted, importedDocument == nil, !openingFile, !showsHistory,
              historicalMesh == nil else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--history-sample"), !hasSeededHistoryPreview {
            hasSeededHistoryPreview = true
            history.recordPreviewSample(SampleFaceMesh.make(),
                                        id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
            openHistoryList()
            return
        }
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
        showsFilterSettings = false
        resultPointSizeScale = 1
        scanFilter.reset()
        historicalMesh = nil
        historicalEntry = nil
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
        historicalMesh = nil
        historicalEntry = nil
        showsFilterSettings = false
        resultPointSizeScale = 1
        scanFilter.reset()
        hasEnteredCapture = true
        sampleMesh = nil
        finalSnapshot = nil
        syntheticSnapshot = nil
        showsLiveSample = false
        savedNotice = false
        wantsToScan = true
        scanner.reset()
        if scanner.phase == .ready {
            wantsToScan = false
            scanner.startScan()
        } else if scanner.phase == .unavailable {
            wantsToScan = false
        }
    }

    private func revokeConsent() {
        showsHistory = false
        historicalMesh = nil
        historicalEntry = nil
        history.clearAll()
        showsFilterSettings = false
        resultPointSizeScale = 1
        scanFilter.reset()
        privacy.revoke()
        scanner.stop()
        cancelExport()
        importGeneration = UUID()
        importTask?.cancel()
        importTask = nil
        importedDocument = nil
        openingFile = false
        openingHistory = false
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

    private func applyFilter() {
        guard privacy.isAccepted, !exporting, !openingFile, importedDocument == nil,
              let originalMesh else { return }
        savedNotice = false
        scanFilter.start(originalMesh, settings: filterSettings)
    }

    private func clearErrors() {
        exportError = nil
        scanFilter.errorMessage = nil
        history.errorMessage = nil
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
        showsHistory = false
        openingHistory = false
        showsFilterSettings = false
        scanFilter.cancel()
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
        openingHistory = false
        if importedDocument == nil { restoreCapture() }
    }

    private func closeFile() {
        importedDocument = nil
        restoreCapture()
    }

    private func restoreCapture() {
        guard importedDocument == nil, !openingFile, !showsHistory else { return }
        if historicalMesh == nil {
            scanner.allowCaptureAfterFileViewing()
            if hasEnteredCapture, privacy.isAccepted { scanner.prepare() }
        }
    }

    private func openHistoryList() {
        guard privacy.isAccepted else { showsPrivacy = true; return }
        wantsToScan = false
        scanFilter.cancel()
        scanner.suspendCaptureForFileViewing()
        history.refresh()
        showsHistory = true
    }

    private func openHistory(_ entry: ScanHistoryEntry) {
        guard privacy.isAccepted else { return }
        scanFilter.cancel()
        showsFilterSettings = false
        wantsToScan = false
        scanner.suspendCaptureForFileViewing()
        cancelExport()
        pickerGeneration = UUID()
        choosingFile = false
        importTask?.cancel()
        let token = UUID()
        importGeneration = token
        openingHistory = true
        openingFile = true
        showsHistory = false
        importTask = Task {
            do {
                let source = try await history.load(entry)
                guard !Task.isCancelled, importGeneration == token, privacy.isAccepted else { return }
                scanFilter.reset()
                resultPointSizeScale = 1
                savedNotice = false
                historicalEntry = entry
                historicalMesh = source
                importedDocument = nil
                openingFile = false
                openingHistory = false
                importTask = nil
            } catch {
                guard !Task.isCancelled, importGeneration == token else { return }
                openingFile = false
                openingHistory = false
                importTask = nil
                errorTitle = "无法打开历史"
                exportError = error.localizedDescription
                restoreCapture()
            }
        }
    }

    private func closeHistory() {
        historicalMesh = nil
        historicalEntry = nil
        scanFilter.reset()
        savedNotice = false
        restoreCapture()
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


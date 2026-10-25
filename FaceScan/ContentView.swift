import ARKit
import SwiftUI

struct ContentView: View {
    @StateObject private var privacy: PrivacyConsentStore
    @StateObject private var scanner: FaceScanController
    @StateObject private var history: ScanHistoryStore
    @StateObject private var scanFilter = ScanFilterController()
    @StateObject private var scanEnhancement = ScanEnhancementController()
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
    @State private var resultStyle: MeshDisplayStyle = .points
    @State private var filterSettings = ScanFilterSettings.load()
    @State private var showsFilterSettings = false
    @State private var enhancementSettings = ScanEnhancementSettings.load()
    @State private var appliedEnhancementSettings: ScanEnhancementSettings?
    @State private var displayPreferences = ScanDisplayPreferences.load()
    @State private var showsPresentationSettings = false
    @State private var isEnhancementEnabled = false
    @State private var showsFilterStatistics = false
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
    private var enhancedPresentation: ScanEnhancementController.Presentation? {
        mesh.flatMap { scanEnhancement.result(for: $0) }
    }
    private var presentationMesh: ScanMesh? {
        mesh.map { scanEnhancement.displayedMesh(for: $0, isEnabled: isEnhancementEnabled) }
    }
    private var showsEnhancedPoints: Bool { isEnhancementEnabled && enhancedPresentation != nil }
    private var usesLivePointSize: Bool { historicalMesh == nil && (isScanning || showsLiveSample) }
    private var activePointSizeScale: Double {
        usesLivePointSize ? displayPreferences.livePointSizeScale : displayPreferences.resultPointSizeScale
    }
    private var pointSizeBinding: Binding<Double> {
        Binding(get: { activePointSizeScale }, set: { scale in
            if usesLivePointSize { displayPreferences.livePointSizeScale = scale }
            else { displayPreferences.resultPointSizeScale = scale }
        })
    }
    private var filterPresetLabel: String {
        if filterSettings.smoothingCurve != nil { return "自定义 · 曲线" }
        return filterSettings == .gentle ? "轻度" : (filterSettings == .reference ? "参考参数" : "自定义")
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
                .disabled(exporting || openingFile)
                .accessibilityLabel("扫描历史")
                .accessibilityIdentifier("history.open")
                Button {
                    wantsToScan = false
                    scanFilter.cancel()
                    scanEnhancement.cancel()
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

            if showsPoints, importedDocument == nil, !openingFile {
                ScanPointSizeControl(title: usesLivePointSize ? "扫描点大小" : "结果点大小",
                                     scale: pointSizeBinding, compact: true)
                    .disabled(!usesLivePointSize && resultStyle == .color
                              && !(presentationMesh?.triangleIndices.isEmpty ?? true))
            }

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
        .onChange(of: scanFilter.isFiltering) { _, filtering in
            if filtering { scanEnhancement.cancel() }
            else { refreshEnhancementForSelectedSource() }
        }
        .onChange(of: filterSettings) { _, settings in settings.save() }
        .onChange(of: enhancementSettings) { _, settings in settings.save() }
        .onChange(of: displayPreferences) { _, preferences in preferences.save() }
        .onChange(of: mesh?.renderIdentity) { _, _ in refreshEnhancementForSelectedSource() }
        .onChange(of: isEnhancementEnabled) { _, enabled in
            if enabled { applyEnhancement() }
            else { scanEnhancement.cancel() }
        }
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
        .sheet(isPresented: $showsPresentationSettings) {
            ScanPresentationSettingsView(settings: $enhancementSettings,
                                         isEnabled: $isEnhancementEnabled,
                                         pointSizeScale: $displayPreferences.resultPointSizeScale) {
                showsPresentationSettings = false
                applyEnhancement()
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
            Button("好", role: .cancel) { clearErrors() }
        } message: { Text(activeErrorMessage ?? "请重试。") }
    }

    private var activeErrorTitle: String {
        if scanEnhancement.errorMessage != nil { return "无法增强显示" }
        if scanFilter.errorMessage != nil { return "无法滤波" }
        if exportError == nil, history.errorMessage != nil, !showsHistory { return "历史记录" }
        return errorTitle
    }

    private var activeErrorMessage: String? {
        scanEnhancement.errorMessage ?? scanFilter.errorMessage ?? exportError
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
                surfaceMesh: presentationMesh,
                resultFramingIdentity: originalMesh?.renderIdentity,
                displayStyle: mesh == nil ? .points : resultStyle,
                animatesAcquisition: scanner.phase == .scanning || showsLiveSample,
                pointSizeScale: activePointSizeScale,
                isDisplayEnhanced: showsEnhancedPoints)
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
                if !openingFile, !isScanning, !showsLiveSample,
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
        .accessibilityHidden(showsPrivacy)
    }

    private var stageLabel: String {
        if openingFile { return "" }
        if let importedDocument {
            return importedDocument.mesh.isSample ? "合成示例 · PLY 点云" : "PLY 点云"
        }
        let prefix = historicalEntry == nil ? "" : "历史 · "
        if originalMesh?.isSample == true || showsLiveSample {
            let source = mesh?.isFiltered == true ? "合成示例 · 滤波后 · 非真实扫描" : "合成示例 · 非真实扫描"
            return prefix + source + (showsEnhancedPoints ? " · 显示增强" : "")
        }
        if showsEnhancedPoints { return prefix + (mesh?.isFiltered == true ? "滤波后 · 显示增强" : "原始扫描 · 显示增强") }
        if mesh?.isFiltered == true { return prefix + "滤波后 · 观感预览" }
        if filteredResult != nil || historicalEntry != nil { return prefix + "原始扫描" }
        if mesh != nil { return "扫描完成" }
        if isScanning { return "实时点云" }
        return ""
    }

    private var stageHint: String {
        if importedDocument != nil { return "拖动旋转 · 双指缩放 · 双击重置" }
        if mesh != nil { return savedNotice ? "已导出" : "拖动旋转 · 双指缩放 · 双击重置" }
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
                Picker("", selection: $resultStyle) {
                    Text("点云").tag(MeshDisplayStyle.points)
                    Text("原色").tag(MeshDisplayStyle.color)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("显示方式")

                HStack {
                    Button {
                        showsFilterSettings = true
                    } label: {
                        Label("滤波参数", systemImage: "slider.horizontal.3")
                    }
                    .disabled(exporting || scanFilter.isFiltering)
                    .accessibilityValue(filterPresetLabel)
                    Spacer()
                    Button {
                        showsPresentationSettings = true
                    } label: {
                        Label("呈现增强", systemImage: "sparkles")
                    }
                    .disabled(exporting || scanFilter.isFiltering)
                    if isEnhancementEnabled || enhancedPresentation != nil {
                        Toggle("显示增强点云", isOn: $isEnhancementEnabled)
                            .labelsHidden()
                            .fixedSize()
                            .tint(ScanTheme.tint)
                            .accessibilityLabel("显示增强点云")
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .frame(minHeight: 28)

                if let enhancedPresentation, isEnhancementEnabled {
                    Text("显示 \(enhancedPresentation.mesh.vertexCount) 点 · 插值 +\(enhancedPresentation.statistics.addedPointCount)\(enhancedPresentation.statistics.reachedLimit ? " · 达上限" : "") · 仅查看")
                        .font(.system(size: 11))
                        .foregroundStyle(ScanTheme.secondary)
                }

                if let filteredResult {
                    Picker("结果对比", selection: $scanFilter.showsFiltered) {
                        Text("原始").tag(false)
                        Text("滤波后").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(exporting)
                    DisclosureGroup(isExpanded: $showsFilterStatistics) {
                        Text("离群剔除 \(filteredResult.statistics.sorRejectedCount) · 位移剔除 \(filteredResult.statistics.modelRejectedCount)")
                            .foregroundStyle(ScanTheme.secondary)
                    } label: {
                        Text("\(filteredResult.statistics.inputCount) → \(filteredResult.statistics.outputCount) 点 · \(filteredResult.statistics.elapsedSeconds, specifier: "%.1f") 秒")
                    }
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(ScanTheme.secondary)
                    if filteredResult.settings != filterSettings {
                        Text("参数已更改，重新滤波后生效")
                            .font(.system(size: 12))
                            .foregroundStyle(ScanTheme.tint)
                    }
                }

                if scanFilter.isFiltering {
                    HStack {
                        ProgressView("正在滤波…")
                        Spacer()
                        Button("取消") { scanFilter.cancel() }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(ScanTheme.secondary)
                }

                if scanEnhancement.isProcessing {
                    HStack {
                        ProgressView("正在补点…")
                        Spacer()
                        Button("取消") { scanEnhancement.cancel() }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(ScanTheme.secondary)
                }

                historySaveStatus

                HStack(spacing: 12) {
                    primaryButton(filteredResult == nil ? "滤波" : "重新滤波",
                                  symbol: "camera.filters", action: applyFilter)
                        .disabled(exporting || scanFilter.isFiltering)
                    primaryButton(exporting ? "正在导出…" : (mesh.isFiltered ? "导出滤波 PLY" : "导出 PLY"),
                                  symbol: "square.and.arrow.up") {
                        export(mesh)
                    }
                    .disabled(exporting || scanFilter.isFiltering || scanEnhancement.isProcessing)
                }
                HStack {
                    if historicalEntry != nil {
                        Button("关闭历史", action: closeHistory)
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    Button("重新扫描", action: restart)
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ScanTheme.secondary)
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
        showsPresentationSettings = false
        scanEnhancement.reset()
        scanFilter.reset()
        historicalMesh = nil
        historicalEntry = nil
        resultStyle = .points
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
        showsPresentationSettings = false
        scanEnhancement.reset()
        showsFilterSettings = false
        scanFilter.reset()
        resultStyle = .points
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
        showsHistory = false
        historicalMesh = nil
        historicalEntry = nil
        history.clearAll()
        showsPresentationSettings = false
        isEnhancementEnabled = false
        appliedEnhancementSettings = nil
        scanEnhancement.reset()
        showsFilterSettings = false
        scanFilter.reset()
        resultStyle = .points
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
        scanEnhancement.cancel()
        scanFilter.start(originalMesh, settings: filterSettings)
    }

    private func applyEnhancement() {
        guard privacy.isAccepted, !exporting, !openingFile, !choosingFile, importedDocument == nil,
              !scanFilter.isFiltering, let mesh else { return }
        resultStyle = .points
        appliedEnhancementSettings = enhancementSettings
        scanEnhancement.start(mesh, settings: enhancementSettings)
    }

    private func refreshEnhancementForSelectedSource() {
        guard isEnhancementEnabled, privacy.isAccepted, !scanFilter.isFiltering,
              !openingFile, !choosingFile, !showsHistory, importedDocument == nil,
              let mesh else { scanEnhancement.cancel(); return }
        scanEnhancement.start(mesh, settings: appliedEnhancementSettings ?? enhancementSettings)
    }

    private func clearErrors() {
        exportError = nil
        scanFilter.errorMessage = nil
        scanEnhancement.errorMessage = nil
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
        showsPresentationSettings = false
        scanEnhancement.cancel()
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
        refreshEnhancementForSelectedSource()
    }

    @ViewBuilder
    private var historySaveStatus: some View {
        if historicalEntry == nil, sampleMesh == nil {
            if history.isSaving {
                Text("正在保存原始扫描至历史…")
                    .font(.system(size: 11))
                    .foregroundStyle(ScanTheme.secondary)
            } else if history.hasFailedSaves {
                Button("原始历史保存失败，点此重试") { history.retryFailedSaves() }
                    .font(.system(size: 12))
                    .foregroundStyle(ScanTheme.destructive)
            } else if let source = scanner.result, history.entries.contains(where: { $0.id == source.renderIdentity }) {
                Text("原始扫描已保存至历史")
                    .font(.system(size: 11))
                    .foregroundStyle(ScanTheme.secondary)
            }
        }
    }

    private func openHistoryList() {
        guard privacy.isAccepted else { showsPrivacy = true; return }
        wantsToScan = false
        scanFilter.cancel()
        scanEnhancement.cancel()
        scanner.suspendCaptureForFileViewing()
        history.refresh()
        showsHistory = true
    }

    private func openHistory(_ entry: ScanHistoryEntry) {
        guard privacy.isAccepted else { return }
        scanFilter.cancel()
        scanEnhancement.cancel()
        showsFilterSettings = false
        showsPresentationSettings = false
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
                scanEnhancement.reset()
                resultStyle = .points
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
        scanEnhancement.reset()
        resultStyle = .points
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


import SwiftUI

/// Editing a parameter does not start work; the completed scan is processed
/// only when the user explicitly applies this configuration.
struct ScanFilterSettingsView: View {
    @Binding var settings: ScanFilterSettings
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var presetName: String {
        if settings == .gentle { return "轻度" }
        if settings == .reference { return "参考参数" }
        return "自定义"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        presetButton("轻度", value: .gentle)
                        presetButton("参考参数", value: .reference)
                    }
                    LabeledContent("当前参数", value: presetName)
                        .font(.subheadline)
                } footer: {
                    Text("轻度预设减少平滑并保留原始颜色。调整后点“应用并滤波”，每次都从原始扫描重新计算。")
                }

                geometrySection
                outlierSection
                colorSection
                coordinateSection
            }
            .scrollContentBackground(.hidden)
            .background(ScanTheme.background)
            .foregroundStyle(ScanTheme.primary)
            .tint(ScanTheme.tint)
            .navigationTitle("滤波参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if !settings.isValid {
                        Text("请检查参数范围后再应用。")
                            .font(.caption)
                            .foregroundStyle(ScanTheme.destructive)
                    }
                    Button(action: onApply) {
                        Text("应用并滤波")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(ScanPrimaryButton())
                    .disabled(!settings.isValid)
                    .accessibilityIdentifier("filterSettings.apply")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(ScanTheme.background)
                .overlay(alignment: .top) {
                    Rectangle().fill(ScanTheme.border.opacity(0.7)).frame(height: 0.5)
                }
            }
        }
        .onChange(of: settings.medianWindow) { _, window in
            settings.minimumMedianObservations = min(settings.minimumMedianObservations, window * window)
        }
    }

    private var geometrySection: some View {
        Section {
            millimeterSlider("网格间距", value: $settings.parameterGridSize, range: 0.5...4, step: 0.25)
            Stepper(value: $settings.medianWindow, in: 1...31, step: 2) {
                parameterLabel("中值窗口", value: settings.medianWindow == 1
                    ? "关闭" : "\(settings.medianWindow) × \(settings.medianWindow)")
            }
            .accessibilityIdentifier("filterSettings.medianWindow")
            Stepper(value: $settings.minimumMedianObservations,
                    in: 1...max(1, settings.medianWindow * settings.medianWindow)) {
                parameterLabel("中值最少观测格", value: "\(settings.minimumMedianObservations)")
            }
            .disabled(settings.medianWindow == 1)
            .accessibilityIdentifier("filterSettings.minimumMedianObservations")
            Stepper(value: $settings.bilateralIterations, in: 0...32) {
                parameterLabel("双边滤波次数", value: settings.bilateralIterations == 0
                    ? "关闭" : "\(settings.bilateralIterations) 次")
            }
            .accessibilityIdentifier("filterSettings.bilateralIterations")
            Group {
                Stepper(value: $settings.bilateralHalfWindow, in: 0...15) {
                    parameterLabel("双边半窗口", value: "\(settings.bilateralHalfWindow) 格")
                }
                .accessibilityIdentifier("filterSettings.bilateralHalfWindow")
                millimeterSlider("空间 σ", value: $settings.bilateralSpatialSigma, range: 0.25...10, step: 0.25)
                millimeterSlider("半径差 σ", value: $settings.bilateralRadiusSigma, range: 0.25...15, step: 0.25)
            }
            .disabled(settings.bilateralIterations == 0)
        } header: {
            Text("几何平滑")
        } footer: {
            Text("保留细节可先减小网格间距、双边次数和半径差 σ。中值窗口设为关闭可减少局部平滑；网格融合仍会改变点的位置。")
        }
    }

    private var outlierSection: some View {
        Section {
            Stepper(value: $settings.sorNeighbors, in: 1...1024) {
                parameterLabel("SOR 邻点数", value: "\(settings.sorNeighbors)")
            }
            .accessibilityIdentifier("filterSettings.sorNeighbors")
            valueSlider("SOR 标准差倍数", value: $settings.sorStandardDeviations,
                        range: 0...8, step: 0.1, unit: "σ")
            millimeterSlider("最大径向位移", value: $settings.maximumRadialDisplacement,
                             range: 0...40, step: 0.5)
        } header: {
            Text("删点门限")
        } footer: {
            Text("SOR 标准差倍数越大，删除的孤立点越少。最大径向位移越小，超出门限而被删除的点越多；它不会限制剩余点的平滑强度。")
        }
    }

    private var colorSection: some View {
        Section {
            Toggle("颜色去噪", isOn: $settings.filterColors)
                .accessibilityIdentifier("filterSettings.filterColors")
            if settings.filterColors {
                millimeterSlider("颜色径向门限", value: $settings.colorRadialGate, range: 0...15, step: 0.25)
                millimeterSlider("颜色空间 σ", value: $settings.colorSpatialSigma, range: 0.25...8, step: 0.25)
                valueSlider("RGB 差异 σ", value: $settings.colorRGBSigma, range: 1...100, step: 1, unit: "")
                Stepper(value: $settings.colorHalfWindow, in: 0...15) {
                    parameterLabel("颜色半窗口", value: "\(settings.colorHalfWindow) 格")
                }
                .accessibilityIdentifier("filterSettings.colorHalfWindow")
            }
        } header: {
            Text("颜色")
        } footer: {
            Text("关闭后保留来源点的原始 RGB。开启时，较小的颜色空间 σ 和 RGB 差异 σ 有助于保留颜色边缘。")
        }
    }

    private var coordinateSection: some View {
        Section {
            DisclosureGroup("柱面坐标（高级）") {
                millimeterSlider("柱心 X", value: $settings.cylinderCenterX, range: -100...100, step: 1)
                millimeterSlider("柱心 Z", value: $settings.cylinderCenterZ, range: -150...50, step: 1)
                millimeterSlider("参考半径", value: $settings.referenceRadius, range: 20...200, step: 1)
            }
        } footer: {
            Text("长度均以毫米显示。柱心和参考半径决定柱面参数化，一般保持默认即可。更细的网格会增加耗时与内存使用。")
        }
    }

    private func presetButton(_ title: String, value: ScanFilterSettings) -> some View {
        Button {
            settings = value
        } label: {
            HStack(spacing: 6) {
                if settings == value { Image(systemName: "checkmark") }
                Text(title)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .tint(ScanTheme.tint)
        .accessibilityLabel("使用\(title)预设")
    }

    private func parameterLabel(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(ScanTheme.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func millimeterSlider(_ title: String, value: Binding<Double>,
                                  range: ClosedRange<Double>, step: Double) -> some View {
        let millimeters = Binding(get: { value.wrappedValue * 1_000 },
                                  set: { value.wrappedValue = $0 / 1_000 })
        return valueSlider(title, value: millimeters, range: range, step: step, unit: "mm")
    }

    private func valueSlider(_ title: String, value: Binding<Double>,
                             range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        // Valid settings restored from storage may lie outside the usual slider
        // range. Include that value without silently changing it on presentation.
        let visibleRange = min(range.lowerBound, value.wrappedValue)...max(range.upperBound, value.wrappedValue)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text("\(value.wrappedValue, specifier: step < 1 ? "%.2f" : "%.0f")\(unit.isEmpty ? "" : " \(unit)")")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(ScanTheme.secondary)
                    .fixedSize()
            }
            Slider(value: value, in: visibleRange, step: step)
                .accessibilityLabel(title)
                .accessibilityValue("\(value.wrappedValue, specifier: "%.2f") \(unit)")
        }
        .padding(.vertical, 4)
    }
}

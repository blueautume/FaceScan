import SwiftUI

struct ScanPresentationSettingsView: View {
    @Binding var settings: ScanEnhancementSettings
    @Binding var isEnabled: Bool
    @Binding var pointSizeScale: Double
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("显示增强点云", isOn: $isEnabled)
                        .accessibilityIdentifier("presentation.enabled")
                    ScanPointSizeControl(title: "结果点大小", scale: $pointSizeScale)
                } footer: {
                    Text("点大小立即生效，点击倍数可快速选择预设。补点参数调整后，点“应用并增强”重新计算；每份结果使用固定采样，旋转时保持稳定。")
                }

                densitySection
                boundarySection
                budgetSection
            }
            .scrollContentBackground(.hidden)
            .background(ScanTheme.background)
            .foregroundStyle(ScanTheme.primary)
            .tint(ScanTheme.tint)
            .navigationTitle("呈现增强")
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
                    Button {
                        isEnabled = true
                        onApply()
                    } label: {
                        Text("应用并增强")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(ScanPrimaryButton())
                    .disabled(!settings.isValid)
                    .accessibilityIdentifier("presentation.apply")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(ScanTheme.background)
                .overlay(alignment: .top) {
                    Rectangle().fill(ScanTheme.border.opacity(0.7)).frame(height: 0.5)
                }
            }
        }
    }

    private var densitySection: some View {
        Section {
            Picker("表面采样倍率", selection: $settings.resolutionMultiplier) {
                ForEach([1.0, 2, 4, 8, 16], id: \.self) { value in
                    Text("\(value, specifier: "%.0f")×").tag(value)
                }
                if ![1.0, 2, 4, 8, 16].contains(settings.resolutionMultiplier) {
                    Text("\(settings.resolutionMultiplier, specifier: "%.2f")×")
                        .tag(settings.resolutionMultiplier)
                }
            }
            .accessibilityIdentifier("presentation.resolutionMultiplier")
            millimeterSlider("目标点间距", value: $settings.targetSpacing,
                             range: 0.2...2, step: 0.1)
            millimeterSlider("局部拟合半径", value: $settings.supportRadius,
                             range: 2...8, step: 0.5)
            millimeterSlider("允许补点跨度", value: $settings.maximumGap,
                             range: 1...6, step: 0.25)
        } header: {
            Text("表面加密")
        } footer: {
            Text("倍率表示近似单位面积点数倍率，4×约使原始点距减半，密集区域也会细分。目标点间距是全表面的最大目标间距，与倍率细分后的局部点距取更细者；实际加密受点数上限和边界保护约束。允许跨度限制跨空隙连接，大缺口保持空缺。")
        }
    }

    private var boundarySection: some View {
        Section {
            valueSlider("几何边缘保护", value: Binding(
                get: { Double(settings.edgeProtection) * 100 },
                set: { settings.edgeProtection = Float($0 / 100) }),
                        range: 0...100, step: 5, unit: "%")
            valueSlider("颜色差异容许值", value: Binding(
                get: { Double(settings.colorTolerance) },
                set: { settings.colorTolerance = Float($0) }),
                        range: 10...150, step: 5, unit: "RGB")
        } header: {
            Text("边界保护")
        } footer: {
            Text("几何保护越高，起伏、转折和分层附近的补点越保守。颜色容许值越小，越少跨颜色边界插值；颜色按每通道 0–255 的 RGB 向量差比较。")
        }
    }

    private var budgetSection: some View {
        Section {
            Picker("显示点数上限", selection: $settings.maximumPointCount) {
                Text("10 万").tag(100_000)
                Text("20 万").tag(200_000)
                Text("30 万").tag(300_000)
                Text("40 万").tag(400_000)
                if ![100_000, 200_000, 300_000, 400_000].contains(settings.maximumPointCount) {
                    Text("\(settings.maximumPointCount) 点").tag(settings.maximumPointCount)
                }
            }
            .accessibilityIdentifier("presentation.maximumPointCount")
        } footer: {
            Text("达到上限会停止新增，已有来源点始终保留。倍率是采样目标，不保证输出点数恰好成倍。增强仅用于显示，不改写原始或滤波坐标；常规 PLY 导出仍保存所选扫描数据。加密能改善连续感，不能恢复未采到的细节。")
        }
    }

    private func millimeterSlider(_ title: String, value: Binding<Float>,
                                  range: ClosedRange<Double>, step: Double) -> some View {
        valueSlider(title, value: Binding(
            get: { Double(value.wrappedValue) * 1_000 },
            set: { value.wrappedValue = Float($0 / 1_000) }),
                    range: range, step: step, unit: "mm")
    }

    private func valueSlider(_ title: String, value: Binding<Double>,
                             range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        let visibleRange = min(range.lowerBound, value.wrappedValue)...max(range.upperBound, value.wrappedValue)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text("\(value.wrappedValue, specifier: step < 1 ? "%.2f" : "%.0f") \(unit)")
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

/// One control is reused for live capture and completed-result display.
struct ScanPointSizeControl: View {
    let title: String
    @Binding var scale: Double
    var compact = false

    var body: some View {
        if compact {
            HStack(spacing: 8) {
                Text(title)
                Slider(value: safeScale, in: 0.25...4, step: 0.05)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(safeScale.wrappedValue, specifier: "%.2f") 倍")
                    .accessibilityIdentifier("pointSize.\(title)")
                scaleMenu
                Button("重置") { scale = 1 }
                    .accessibilityLabel("恢复\(title)为一倍")
            }
            .font(.system(size: 12, weight: .medium))
            .tint(ScanTheme.tint)
        } else {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                scaleMenu
                Button("重置") { scale = 1 }
                    .accessibilityLabel("恢复\(title)为一倍")
            }
            .font(.system(size: 12, weight: .medium))
            Slider(value: safeScale, in: 0.25...4, step: 0.05)
                .accessibilityLabel(title)
                .accessibilityValue("\(safeScale.wrappedValue, specifier: "%.2f") 倍")
                .accessibilityIdentifier("pointSize.\(title)")
        }
        .tint(ScanTheme.tint)
        }
    }

    private var safeScale: Binding<Double> {
        Binding(get: { scale.isFinite ? min(4, max(0.25, scale)) : 1 },
                set: { scale = min(4, max(0.25, $0)) })
    }

    private var scaleMenu: some View {
        Menu {
            ForEach([0.25, 0.5, 1, 1.5, 2, 3, 4], id: \.self) { value in
                Button {
                    scale = value
                } label: {
                    if value == safeScale.wrappedValue {
                        Label("\(value, specifier: "%.2f")×", systemImage: "checkmark")
                    } else { Text("\(value, specifier: "%.2f")×") }
                }
            }
        } label: {
            Text("\(safeScale.wrappedValue, specifier: "%.2f")×")
                .monospacedDigit()
        }
        .accessibilityLabel("选择\(title)预设")
        .accessibilityValue("\(safeScale.wrappedValue, specifier: "%.2f") 倍")
    }
}

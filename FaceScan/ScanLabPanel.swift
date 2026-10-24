import SwiftUI

/// A temporary inspector designed to stay at half height while the model remains visible.
struct ScanLabPanel: View {
    @Binding var settings: ScanLabSettings
    let onReplay: () -> Void
    let onDemo: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var appearanceExpanded = true
    @State private var flyInExpanded = true
    @State private var pulseExpanded = false
    @State private var filterExpanded = false
    @State private var meshExpanded = false
    @State private var cameraExpanded = false
    @State private var overlaysExpanded = false
    @State private var demoExpanded = false

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    introduction
                    presets
                    demo
                }
                appearance
                flyIn
                pulse
                filtering
                mesh
                camera
                overlays
                reset
            }
            .navigationTitle("效果实验室")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(ScanTheme.background)
            .tint(ScanTheme.tint)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var introduction: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("边看边调，即时预览", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                Text("将面板停在半屏即可观察模型。可以暂停采集后慢慢调节；飞入效果在采集或演示时出现。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(action: onReplay) {
                        Label("重播飞入", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settings.flyInEnabled)
                    Button(action: onDemo) {
                        Label("合成扫描演示", systemImage: "person.crop.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .font(.caption.weight(.medium))
            }
            .padding(.vertical, 4)
        }
    }

    private var presets: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(ScanLabPreset.allCases) { preset in
                        Button {
                            settings.apply(preset)
                        } label: {
                            VStack(spacing: 7) {
                                Image(systemName: preset.symbol)
                                    .font(.title3)
                                Text(preset.title)
                                    .font(.caption.weight(.medium))
                            }
                            .frame(width: 68, height: 62)
                            .background(ScanTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(ScanTheme.tint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("应用\(preset.title)预设")
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("快速预设")
        } footer: {
            Text("预设会替换当前外观、动画与滤波参数，可继续微调。辅助信息与演示噪声会保留，便于对比同一份数据。")
        }
    }

    private var demo: some View {
        Section {
            DisclosureGroup(isExpanded: $demoExpanded) {
                LabSlider(title: "演示噪声", hint: "只为合成演示加入位置扰动，便于比较滤波前后。真机采集和导入模型不加噪声。", value: $settings.demoNoise, range: 0...0.006, format: "%.1f mm", scale: 1_000)
                Text("演示中调整噪声会重新生成点云。设为 0 可观察无噪声的基准效果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } label: {
                sectionLabel("演示数据", symbol: "testtube.2", detail: "合成点云")
            }
        }
    }

    private var appearance: some View {
        Section {
            DisclosureGroup(isExpanded: $appearanceExpanded) {
                LabPicker(title: "模型形式", hint: "实体、线框和混合模式需要邻接网格；稀疏区域可能留白。", selection: $settings.displayMode, options: ScanLabDisplayMode.allCases) { $0.title }
                LabPicker(title: "颜色", hint: "原色还原采集色；深度、高度和法线色便于观察形状。", selection: $settings.colorMode, options: ScanLabColorMode.allCases) { $0.title }
                LabPicker(title: "背景", hint: "深背景突出光点，浅背景更适合检查实体轮廓。", selection: $settings.background, options: ScanLabBackground.allCases) { $0.title }
                LabSlider(title: "点大小", hint: "更大的点更饱满，也可能遮住鼻唇等小细节。", value: $settings.pointSize, range: 0.5...6, format: "%.1f px")
                LabSlider(title: "点密度", hint: "只减少预览绘制的点数；越低越轻盈，原始点仍保留。", value: $settings.pointDensity, range: 0.1...1, format: "%.0f%%", scale: 100)
                LabSlider(title: "不透明度", hint: "降低后可观察前后层叠的点与内部轮廓。", value: $settings.opacity, range: 0.1...1, format: "%.0f%%", scale: 100)
                LabSlider(title: "亮度", hint: "放大或减弱模型颜色的亮度。", value: $settings.exposure, range: 0.25...2.5, format: "%.2f×")
                LabSlider(title: "饱和度", hint: "0 为灰度；增大后突出模型本身的色彩。", value: $settings.saturation, range: 0...2, format: "%.2f×")
                LabSlider(title: "辉光", hint: "给明亮区域增加柔光；深色背景下更明显。", value: $settings.glow, range: 0...2, format: "%.2f")
                LabToggle(title: "颜色叠亮", hint: "重叠的粒子叠加亮度，形成更通透的光点。", isOn: $settings.additiveBlending)
            } label: {
                sectionLabel("模型与色彩", symbol: "circle.lefthalf.filled", detail: settings.displayMode.title)
            }
        }
    }

    private var flyIn: some View {
        Section {
            DisclosureGroup(isExpanded: $flyInExpanded) {
                LabToggle(title: "粒子从面前飞入", hint: "新采集的点从面部正前方飞向各自位置；可用重播和演示观察。", isOn: $settings.flyInEnabled)
                Group {
                    LabSlider(title: "飞入时长", hint: "每颗粒子到达表面的时间；越长越舒缓。", value: $settings.flyInDuration, range: 0.15...3, format: "%.2f 秒")
                    LabSlider(title: "起飞距离", hint: "粒子起点距面部的前向距离。", value: $settings.flyInDistance, range: 0.01...0.5, format: "%.0f mm", scale: 1_000)
                    LabSlider(title: "横向散开", hint: "起点向周围扩散的范围；0 时沿正前方向凝聚。", value: $settings.flyInSpread, range: 0...0.25, format: "%.0f mm", scale: 1_000)
                    LabSlider(title: "旋流圈数", hint: "给飞行轨迹增加弧形旋转，0 为直接飞入。", value: $settings.flyInSwirl, range: 0...3, format: "%.2f 圈")
                    LabSlider(title: "错峰时间", hint: "让粒子分批起飞，增加前后层次；0 时同时起飞。", value: $settings.flyInStagger, range: 0...1.5, format: "%.2f 秒")
                }
                .disabled(!settings.flyInEnabled)
            } label: {
                sectionLabel("粒子飞入", symbol: "sparkles", detail: settings.flyInEnabled ? "已开启" : "已关闭")
            }
        }
    }

    private var pulse: some View {
        Section {
            DisclosureGroup(isExpanded: $pulseExpanded) {
                LabToggle(title: "呼吸起伏", hint: "让点位轻微往复起伏，适合观察点云的生命感。", isOn: $settings.pulseEnabled)
                Group {
                    LabSlider(title: "呼吸速度", hint: "控制起伏的快慢。", value: $settings.pulseSpeed, range: 0.1...3, format: "%.2f×")
                    LabSlider(title: "起伏幅度", hint: "点位偏移仅作用于显示，数值越大形变越明显。", value: $settings.pulseAmplitude, range: 0...0.01, format: "%.1f mm", scale: 1_000)
                }
                .disabled(!settings.pulseEnabled)
            } label: {
                sectionLabel("呼吸动效", symbol: "waveform.path", detail: settings.pulseEnabled ? "已开启" : "已关闭")
            }
        }
    }

    private var filtering: some View {
        Section {
            DisclosureGroup(isExpanded: $filterExpanded) {
                LabToggle(title: "启用预览滤波", hint: "对展示点云平滑去噪；关闭可直接比较原始细节。", isOn: $settings.filterEnabled)
                Group {
                    LabPicker(title: "滤波方式", hint: settings.filterMode.explanation, selection: $settings.filterMode, options: ScanLabFilterMode.allCases) { $0.title }
                    LabSlider(title: "平滑强度", hint: "控制滤波结果与原点的混合比例，0 保留原位置。", value: $settings.filterStrength, range: 0...1, format: "%.0f%%", scale: 100)
                    LabStepper(title: "滤波次数", hint: "重复处理会更平滑，也会增加计算量与细节损失。", value: $settings.filterPasses, range: 1...3, suffix: "次")
                }
                .disabled(!settings.filterEnabled)
                LabSlider(title: "邻域半径", hint: "滤波与孤立点判断共同使用这个范围；过大会抹平眼睑等小结构。", value: $settings.filterRadius, range: 0.002...0.02, format: "%.1f mm", scale: 1_000)
                    .disabled(!settings.filterEnabled && !settings.outlierRemovalEnabled)
                LabToggle(title: "去除孤立点", hint: "隐藏附近缺少邻点的零散噪点，可与平滑独立开启。", isOn: $settings.outlierRemovalEnabled)
                LabStepper(title: "最少邻点数", hint: "使用上方邻域半径判断；提高后剔除更积极，也可能减少边缘。", value: $settings.outlierMinNeighbors, range: 1...8, suffix: "个")
                    .disabled(!settings.outlierRemovalEnabled)
            } label: {
                sectionLabel("滤波与去噪", symbol: "line.3.horizontal.decrease.circle", detail: settings.filterEnabled ? settings.filterMode.title : "原始点位")
            }
        } footer: {
            if filterExpanded {
                Text("点数较多时，滤波可能需要片刻完成。建议先暂停采集，再比较参数。")
            }
        }
    }

    private var mesh: some View {
        Section {
            DisclosureGroup(isExpanded: $meshExpanded) {
                LabToggle(title: "叠加线框", hint: "在当前模型上额外叠加三角线框；三角线框模式始终显示线框。", isOn: $settings.meshEnabled)
                LabSlider(title: "网格透明度", hint: "调低以对照点云与表面的贴合程度。", value: $settings.meshOpacity, range: 0.05...1, format: "%.0f%%", scale: 100)
                LabSlider(title: "最大连接边长", hint: "超过此长度不连面；小值减少跨越缺口，大值连接更多区域。", value: $settings.meshEdgeLimit, range: 0.003...0.035, format: "%.1f mm", scale: 1_000)
                LabStepper(title: "网格采样步长", hint: "控制实时邻接网格的细密程度；1 最细。模型已有的源三角面保持连续，不使用此参数。", value: $settings.meshStride, range: 1...5, suffix: "级")
                LabToggle(title: "平滑法线", hint: "柔化三角面之间的光照过渡；关闭后呈现多面体质感。", isOn: $settings.smoothNormals)
                LabSlider(title: "金属度", hint: "在实体表面上调节金属反射感。", value: $settings.metalness, range: 0...1, format: "%.0f%%", scale: 100)
                LabSlider(title: "粗糙度", hint: "低值偏光亮，高值偏哑光；实体表面上最明显。", value: $settings.roughness, range: 0.05...1, format: "%.0f%%", scale: 100)
                LabSlider(title: "灯光强度", hint: "调节实体表面的照明亮度；原色粒子不依赖灯光。", value: $settings.lightIntensity, range: 100...2_500, format: "%.0f")
            } label: {
                sectionLabel("网格与材质", symbol: "square.3.layers.3d", detail: meshIsVisible ? "可见" : "收起")
            }
        } footer: {
            if meshExpanded {
                Text("实时扫描按邻近点连接显示网格；完成或导入的模型优先使用源三角面。显示预览不代表封闭、可直接打印的模型。")
            }
        }
    }

    private var camera: some View {
        Section {
            DisclosureGroup(isExpanded: $cameraExpanded) {
                LabToggle(title: "自动摆动", hint: "停止扫描、演示完成或查看文件时，让模型在左右约 54° 范围缓慢摆动。正在采集时暂停摆动。", isOn: $settings.autoRotate)
                LabSlider(title: "摆动速度", hint: "控制左右往复的快慢；负值反向，0 暂停。", value: $settings.rotationSpeed, range: -1...1, format: "%.2f×")
                    .disabled(!settings.autoRotate)
                LabToggle(title: "正交视角", hint: "减弱近大远小的透视感，便于比较正侧面比例。", isOn: $settings.orthographic)
            } label: {
                sectionLabel("观察视角", symbol: "rotate.3d", detail: settings.orthographic ? "正交" : "透视")
            }
        }
    }

    private var overlays: some View {
        Section {
            DisclosureGroup(isExpanded: $overlaysExpanded) {
                LabToggle(title: "坐标轴", hint: "在模型旁显示三个空间方向，帮助判断旋转和深度。", isOn: $settings.showAxes)
                LabToggle(title: "包围盒", hint: "显示点云的空间边界，用于检查离群点与尺寸范围。", isOn: $settings.showBounds)
                LabToggle(title: "相机预览", hint: "显示或隐藏相机画面；不改变相机采集状态。", isOn: $settings.showCameraPreview)
                LabToggle(title: "覆盖引导", hint: "显示或隐藏扫描视角的覆盖提示。", isOn: $settings.showCoverage)
                LabToggle(title: "性能统计", hint: "显示点数与渲染统计。静止预览按需绘制，帧率可能显示为 0；可开呼吸动效观察持续帧率。", isOn: $settings.showStats)
            } label: {
                sectionLabel("辅助显示", symbol: "viewfinder", detail: "5 项")
            }
        }
    }

    private var reset: some View {
        Section {
            Button {
                settings = ScanLabSettings()
            } label: {
                Label("恢复全部实验参数", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .accessibilityHint("恢复默认值，不会清除当前扫描")
        } footer: {
            Text("所有设置只影响当前预览。滤波、粒子动画与邻接网格均不改写原始扫描点或导出的 PLY 文件。退出 App 后恢复默认参数。")
        }
    }

    private var meshIsVisible: Bool {
        settings.meshEnabled || settings.displayMode != .points
    }

    private func sectionLabel(_ title: String, symbol: String, detail: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ScanTheme.primary)
            Spacer(minLength: 8)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct LabSlider: View {
    let title: String
    let hint: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale: Double = 1

    private var formattedValue: String { String(format: format, value * scale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(formattedValue)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(ScanTheme.tint)
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(formattedValue)
                .accessibilityHint(hint)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

private struct LabToggle: View {
    let title: String
    let hint: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline)
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 3)
        }
        .accessibilityHint(hint)
    }
}

private struct LabPicker<Value: Hashable>: View {
    let title: String
    let hint: String
    @Binding var selection: Value
    let options: [Value]
    let optionTitle: (Value) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(optionTitle(option)).tag(option)
                }
            }
            .font(.subheadline)
            .pickerStyle(.menu)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }
}

private struct LabStepper: View {
    let title: String
    let hint: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let suffix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper(value: $value, in: range) {
                HStack {
                    Text(title)
                        .font(.subheadline)
                    Spacer(minLength: 4)
                    Text("\(value) \(suffix)")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(ScanTheme.tint)
                }
            }
            .accessibilityHint(hint)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

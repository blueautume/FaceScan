import SwiftUI

/// Five fixed horizontal knots keep the control predictable on a small screen.
/// The displayed line uses the same evaluation as the geometry processor.
struct ScanSmoothingCurveEditor: View {
    @Binding var curve: FaceCloudSmoothingCurve
    @State private var selectedKnot = 2
    @State private var draggingKnot: Int?
    @State private var dragStartStrength = 0.0

    private let fractions = [0.0, 0.25, 0.5, 0.75, 1.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("拖动控制点或轻点图内，调整平滑强度")
                .font(.caption)
                .foregroundStyle(ScanTheme.secondary)

            graph
                .frame(height: 250)

            HStack {
                Text("起伏 \(fractions[selectedKnot] * curve.maximumVariation * 1_000, specifier: "%.2f") mm")
                Spacer()
                Text("平滑 \(Int((strength(at: selectedKnot) * 100).rounded()))%")
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(ScanTheme.secondary)
            Slider(value: selectedStrength, in: 0...1, step: 0.01)
                .accessibilityLabel("选中控制点的平滑强度")
                .accessibilityValue("\(Int((strength(at: selectedKnot) * 100).rounded()))%")
                .accessibilityIdentifier("smoothingCurve.selectedStrength")

            HStack(spacing: 8) {
                shapeButton("保留起伏", strengths: FaceCloudSmoothingCurve.featurePreserving.strengths)
                shapeButton("统一平滑", strengths: Array(repeating: 1, count: 5))
                shapeButton("不移动", strengths: Array(repeating: 0, count: 5))
            }
            .font(.caption)
        }
        .tint(ScanTheme.tint)
    }

    private var graph: some View {
        GeometryReader { geometry in
            let rect = CGRect(x: 38, y: 30, width: max(1, geometry.size.width - 60),
                              height: max(1, geometry.size.height - 72))
            ZStack(alignment: .topLeading) {
                Path { path in
                    for fraction in fractions {
                        let x = rect.minX + rect.width * fraction
                        path.move(to: CGPoint(x: x, y: rect.minY))
                        path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    }
                    for strength in [0.0, 0.5, 1.0] {
                        let y = rect.maxY - rect.height * strength
                        path.move(to: CGPoint(x: rect.minX, y: y))
                        path.addLine(to: CGPoint(x: rect.maxX, y: y))
                    }
                }
                .stroke(ScanTheme.border.opacity(0.65), lineWidth: 0.7)
                .accessibilityHidden(true)

                curveArea(in: rect)
                    .fill(ScanTheme.accent.opacity(0.25))
                    .accessibilityHidden(true)
                curvePath(in: rect)
                    .stroke(ScanTheme.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .accessibilityHidden(true)

                Text("平滑强度 (%)")
                    .font(.caption)
                    .foregroundStyle(ScanTheme.secondary)
                    .position(x: rect.minX + 46, y: 8)

                ForEach([0, 50, 100], id: \.self) { percent in
                    Text("\(percent)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ScanTheme.secondary)
                        .frame(width: 30, alignment: .trailing)
                        .position(x: 15, y: rect.maxY - rect.height * Double(percent) / 100)
                }

                ForEach(0..<fractions.count, id: \.self) { index in
                    Text("\(fractions[index] * curve.maximumVariation * 1_000, specifier: "%.1f")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ScanTheme.secondary)
                        .position(x: rect.minX + rect.width * fractions[index], y: rect.maxY + 14)

                    Circle()
                        .fill(selectedKnot == index ? ScanTheme.tint : ScanTheme.card)
                        .frame(width: selectedKnot == index ? 15 : 12,
                               height: selectedKnot == index ? 15 : 12)
                        .overlay {
                            Circle().stroke(ScanTheme.tint, lineWidth: 2)
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .position(x: rect.minX + rect.width * fractions[index],
                                  y: rect.maxY - rect.height * strength(at: index))
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("smoothingCurvePlot"))
                                .onChanged { value in
                                    if draggingKnot != index {
                                        draggingKnot = index
                                        dragStartStrength = strength(at: index)
                                    }
                                    selectedKnot = index
                                    setStrength(dragStartStrength - value.translation.height / rect.height, at: index)
                                }
                                .onEnded { _ in draggingKnot = nil }
                        )
                        .accessibilityElement()
                        .accessibilityLabel("起伏 \(fractions[index] * curve.maximumVariation * 1_000, specifier: "%.2f") 毫米控制点")
                        .accessibilityValue("平滑 \(Int((strength(at: index) * 100).rounded()))%")
                        .accessibilityHint("上下轻扫调整强度，或使用下方滑块")
                        .accessibilityAdjustableAction { direction in
                            selectedKnot = index
                            switch direction {
                            case .increment: setStrength(strength(at: index) + 0.05, at: index)
                            case .decrement: setStrength(strength(at: index) - 0.05, at: index)
                            @unknown default: break
                            }
                        }
                        .accessibilityAction { selectedKnot = index }
                        .accessibilityIdentifier("smoothingCurve.knot\(index)")
                }

                Text("局部起伏 (mm)")
                    .font(.caption)
                    .foregroundStyle(ScanTheme.secondary)
                    .position(x: rect.maxX - 45, y: rect.maxY + 35)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    guard rect.contains(value.location) else { return }
                    let fraction = (value.location.x - rect.minX) / rect.width
                    let index = min(4, max(0, Int((fraction * 4).rounded())))
                    selectedKnot = index
                    let handleX = rect.minX + rect.width * fractions[index]
                    let handleY = rect.maxY - rect.height * strength(at: index)
                    // A tap on the handle selects it without a small jump.
                    if hypot(value.location.x - handleX, value.location.y - handleY) > 16 {
                        setStrength((rect.maxY - value.location.y) / rect.height, at: index)
                    }
                }
            )
            .coordinateSpace(name: "smoothingCurvePlot")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("局部起伏与平滑强度曲线")
    }

    private var selectedStrength: Binding<Double> {
        Binding(get: { strength(at: selectedKnot) }, set: { setStrength($0, at: selectedKnot) })
    }

    private func strength(at index: Int) -> Double {
        curve.strengths.indices.contains(index) ? curve.strengths[index] : 0
    }

    private func setStrength(_ value: Double, at index: Int) {
        guard curve.strengths.indices.contains(index) else { return }
        curve.strengths[index] = min(1, max(0, value))
    }

    private func curvePath(in rect: CGRect) -> Path {
        Path { path in
            for sample in 0...160 {
                let fraction = Double(sample) / 160
                let strength = curve.strength(for: fraction * curve.maximumVariation)
                let point = CGPoint(x: rect.minX + rect.width * fraction,
                                    y: rect.maxY - rect.height * strength)
                if sample == 0 { path.move(to: point) }
                else { path.addLine(to: point) }
            }
        }
    }

    private func curveArea(in rect: CGRect) -> Path {
        var path = curvePath(in: rect)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private func shapeButton(_ title: String, strengths: [Double]) -> some View {
        Button {
            curve.strengths = strengths
        } label: {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("曲线预设：\(title)")
    }
}

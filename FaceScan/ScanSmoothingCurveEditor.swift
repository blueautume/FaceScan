import SwiftUI

/// Five fixed horizontal knots keep the control predictable on a small screen.
/// The displayed line uses the same evaluation as the geometry processor.
struct ScanSmoothingCurveEditor: View {
    @Binding var curve: FaceCloudSmoothingCurve
    @State private var selectedKnot = 2
    @State private var draggingKnot: Int?
    @State private var dragStartStrength = 0.0
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var graphHeight = 210.0
    @ScaledMetric(relativeTo: .caption) private var graphLeadingInset = 38.0
    @ScaledMetric(relativeTo: .caption) private var graphTrailingInset = 22.0
    @ScaledMetric(relativeTo: .caption) private var graphBottomInset = 24.0

    private let fractions = [0.0, 0.25, 0.5, 0.75, 1.0]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Drag a point or tap the graph to adjust smoothing.")
                .font(.caption)
                .foregroundStyle(ScanTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Smoothing (%)")
                    .font(.caption)
                    .foregroundStyle(ScanTheme.secondary)
                graph.frame(height: graphHeight)
                Text("Surface Variation (mm)")
                    .font(.caption)
                    .foregroundStyle(ScanTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    variationSummary.fixedSize()
                    Spacer(minLength: 8)
                    smoothingSummary.fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    variationSummary
                    smoothingSummary
                }
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(ScanTheme.secondary)
            Slider(value: selectedStrength, in: 0...1, step: 0.01)
                .accessibilityLabel("Smoothing for Selected Point")
                .accessibilityValue(Text(verbatim: percentage(strength(at: selectedKnot))))
                .accessibilityIdentifier("smoothingCurve.selectedStrength")

            curvePresets.font(.caption)
        }
        .tint(ScanTheme.tint)
    }

    private var graph: some View {
        GeometryReader { geometry in
            let rect = CGRect(x: graphLeadingInset, y: 10,
                              width: max(1, geometry.size.width - graphLeadingInset - graphTrailingInset),
                              height: max(1, geometry.size.height - graphBottomInset - 10))
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

                ForEach([0, 50, 100], id: \.self) { percent in
                    Text(percent, format: .number.locale(locale))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ScanTheme.secondary)
                        .frame(width: graphLeadingInset - 8, alignment: .trailing)
                        .position(x: (graphLeadingInset - 8) / 2,
                                  y: rect.maxY - rect.height * Double(percent) / 100)
                }

                ForEach(0..<fractions.count, id: \.self) { index in
                    if !dynamicTypeSize.isAccessibilitySize || index == 0 || index == fractions.count - 1 {
                        Text(verbatim: number(fractions[index] * curve.maximumVariation * 1_000, digits: 1))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ScanTheme.secondary)
                            .position(x: rect.minX + rect.width * fractions[index],
                                      y: rect.maxY + graphBottomInset / 2)
                    }

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
                        .accessibilityLabel("Control Point at \(number(fractions[index] * curve.maximumVariation * 1_000, digits: 2)) mm Variation")
                        .accessibilityValue("Smoothing \(percentage(strength(at: index)))")
                        .accessibilityHint("Swipe up or down to adjust, or use the slider below.")
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
        .accessibilityLabel("Variation and Smoothing Curve")
    }

    private var variationSummary: Text {
        Text("Variation \(number(fractions[selectedKnot] * curve.maximumVariation * 1_000, digits: 2)) mm")
    }

    private var smoothingSummary: Text {
        Text("Smoothing \(percentage(strength(at: selectedKnot)))")
    }

    @ViewBuilder
    private var curvePresets: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) { presetButtons }
        } else {
            HStack(spacing: 8) { presetButtons }
        }
    }

    @ViewBuilder
    private var presetButtons: some View {
        shapeButton("Keep Detail", accessibilityLabel: "Keep Detail Curve",
                    strengths: FaceCloudSmoothingCurve.featurePreserving.strengths)
        shapeButton("Smooth All", accessibilityLabel: "Smooth All Curve",
                    strengths: Array(repeating: 1, count: 5))
        shapeButton("No Shift", accessibilityLabel: "No Shift Curve",
                    strengths: Array(repeating: 0, count: 5))
    }

    private func number(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).grouping(.never).locale(locale))
    }

    private func percentage(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
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

    private func shapeButton(_ title: LocalizedStringKey, accessibilityLabel: LocalizedStringKey,
                             strengths: [Double]) -> some View {
        Button {
            curve.strengths = strengths
        } label: {
            Text(title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(accessibilityLabel)
    }
}

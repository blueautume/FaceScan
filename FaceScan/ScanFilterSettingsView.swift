import SwiftUI

/// Editing a parameter does not start work; the completed scan is processed
/// only when the user explicitly applies this configuration.
struct ScanFilterSettingsView: View {
    @Binding var settings: ScanFilterSettings
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var lastCurve = ScanFilterSettings.standard.smoothingCurve ?? .featurePreserving

    var body: some View {
        NavigationStack {
            Form {
                curveSection
                geometrySection
                outlierSection
                colorSection
                coordinateSection
            }
            .scrollContentBackground(.hidden)
            .background(ScanTheme.background)
            .foregroundStyle(ScanTheme.primary)
            .tint(ScanTheme.tint)
            .navigationTitle("Filter Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "filter.reset", defaultValue: "Reset")) {
                        settings = .standard
                        lastCurve = ScanFilterSettings.standard.smoothingCurve ?? .featurePreserving
                        settings.save()
                    }
                    .disabled(settings == .standard)
                    .accessibilityIdentifier("filterSettings.reset")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if !settings.isValid {
                        Text("Check the parameter ranges before applying.")
                            .font(.caption)
                            .foregroundStyle(ScanTheme.destructive)
                    }
                    Button {
                        settings.save()
                        onApply()
                    } label: {
                        Text("Save & Filter")
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
        .onAppear {
            if let curve = settings.smoothingCurve { lastCurve = curve }
        }
        .onChange(of: settings.smoothingCurve) { _, curve in
            if let curve { lastCurve = curve }
        }
    }

    private var curveSection: some View {
        Section {
            Toggle("Adaptive Smoothing", isOn: curveEnabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("filterSettings.smoothingCurveEnabled")
            if settings.smoothingCurve != nil {
                ScanSmoothingCurveEditor(curve: curveBinding)
                    .listRowInsets(EdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12))
                millimeterSlider("Variation Range", value: curveBinding.maximumVariation,
                                 range: 0.5...8, step: 0.25)
                millimeterSlider("Neighborhood Radius", value: curveBinding.neighborhoodRadius,
                                 range: 2...8, step: 0.5)
            }
        } header: {
            Text("Smoothing Curve")
        } footer: {
            if settings.smoothingCurve == nil {
                Text("Smooth flatter areas more and preserve larger variations.")
            } else {
                Text("0% keeps positions; 100% applies full smoothing. The last point also controls larger variations. Where the local surface cannot be estimated, adaptive curves keep the original positions; uniform curves still apply. A larger neighborhood radius may help. Outlier removal and color denoising are independent. Noise can also cause variation.")
            }
        }
    }

    private var curveEnabled: Binding<Bool> {
        Binding(get: { settings.smoothingCurve != nil }, set: { enabled in
            if enabled { settings.smoothingCurve = lastCurve }
            else {
                if let curve = settings.smoothingCurve { lastCurve = curve }
                settings.smoothingCurve = nil
            }
        })
    }

    private var curveBinding: Binding<FaceCloudSmoothingCurve> {
        Binding(get: { settings.smoothingCurve ?? lastCurve }, set: { curve in
            lastCurve = curve
            settings.smoothingCurve = curve
        })
    }

    private var geometrySection: some View {
        Section {
            millimeterSlider("Grid Spacing", value: $settings.parameterGridSize, range: 0.5...4, step: 0.25)
            Stepper(value: $settings.medianWindow, in: 1...31, step: 2) {
                parameterLabel("Median Window", value: medianWindowValue)
            }
            .accessibilityIdentifier("filterSettings.medianWindow")
            Stepper(value: $settings.minimumMedianObservations,
                    in: 1...max(1, settings.medianWindow * settings.medianWindow)) {
                parameterLabel("Min. Cells for Median", value: Text(settings.minimumMedianObservations, format: .number.locale(locale)))
            }
            .disabled(settings.medianWindow == 1)
            .accessibilityIdentifier("filterSettings.minimumMedianObservations")
            Stepper(value: $settings.bilateralIterations, in: 0...32) {
                parameterLabel("Bilateral Passes", value: bilateralPassesValue)
            }
            .accessibilityIdentifier("filterSettings.bilateralIterations")
            Group {
                Stepper(value: $settings.bilateralHalfWindow, in: 0...15) {
                    parameterLabel("Bilateral Half-Window", value: Text(verbatim: cellCount(settings.bilateralHalfWindow)))
                }
                .accessibilityIdentifier("filterSettings.bilateralHalfWindow")
                millimeterSlider("Spatial σ", value: $settings.bilateralSpatialSigma, range: 0.25...10, step: 0.25)
                millimeterSlider("Radius Difference σ", value: $settings.bilateralRadiusSigma, range: 0.25...15, step: 0.25)
            }
            .disabled(settings.bilateralIterations == 0)
        } header: {
            Text("Geometry Smoothing")
        } footer: {
            Text("For finer detail, reduce grid spacing, bilateral passes, or radius difference σ. Turn off median filtering for less smoothing. Grid fusion can still move points unless the smoothing curve keeps them in place.")
        }
    }

    private var outlierSection: some View {
        Section {
            Stepper(value: $settings.sorNeighbors, in: 1...1024) {
                parameterLabel("SOR Neighbors", value: Text(settings.sorNeighbors, format: .number.locale(locale)))
            }
            .accessibilityIdentifier("filterSettings.sorNeighbors")
            valueSlider("SOR Threshold", value: $settings.sorStandardDeviations,
                        range: 0...8, step: 0.1, unit: "σ")
            millimeterSlider("Max. Radial Shift", value: $settings.maximumRadialDisplacement,
                             range: 0...40, step: 0.5)
        } header: {
            Text("Outlier Removal")
        } footer: {
            Text("A higher SOR threshold removes fewer outliers. Points that move farther than the radial shift limit are removed, rather than limited to that distance.")
        }
    }

    private var colorSection: some View {
        Section {
            Toggle("Color Denoising", isOn: $settings.filterColors)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("filterSettings.filterColors")
            if settings.filterColors {
                millimeterSlider("Color Radial Gate", value: $settings.colorRadialGate, range: 0...15, step: 0.25)
                millimeterSlider("Color Spatial σ", value: $settings.colorSpatialSigma, range: 0.25...8, step: 0.25)
                valueSlider("RGB Difference σ", value: $settings.colorRGBSigma, range: 1...100, step: 1, unit: "")
                Stepper(value: $settings.colorHalfWindow, in: 0...15) {
                    parameterLabel("Color Half-Window", value: Text(verbatim: cellCount(settings.colorHalfWindow)))
                }
                .accessibilityIdentifier("filterSettings.colorHalfWindow")
            }
        } header: {
            Text("Color")
        } footer: {
            Text("Off keeps source RGB. Lower spatial σ and RGB difference σ help preserve color edges.")
        }
    }

    private var coordinateSection: some View {
        Section {
            DisclosureGroup {
                millimeterSlider("Center X", value: $settings.cylinderCenterX, range: -100...100, step: 1)
                millimeterSlider("Center Z", value: $settings.cylinderCenterZ, range: -150...50, step: 1)
                millimeterSlider("Reference Radius", value: $settings.referenceRadius, range: 20...200, step: 1)
            } label: {
                Text("Cylindrical Grid (Advanced)")
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("Lengths are in millimeters. The center and reference radius define the cylindrical grid; usually keep the defaults. Finer grids use more time and memory.")
        }
    }

    private var medianWindowValue: Text {
        if settings.medianWindow == 1 { return Text("Off") }
        let count = settings.medianWindow.formatted(.number.locale(locale))
        return Text(verbatim: "\(count) × \(count)")
    }

    private var bilateralPassesValue: Text {
        settings.bilateralIterations == 0 ? Text("Off")
            : Text(settings.bilateralIterations, format: .number.locale(locale))
    }

    private func cellCount(_ count: Int) -> String {
        String(localized: "\(count) cells", locale: locale)
    }

    private func parameterLabel(_ title: LocalizedStringKey, value: Text) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            value
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(ScanTheme.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func millimeterSlider(_ title: LocalizedStringKey, value: Binding<Double>,
                                  range: ClosedRange<Double>, step: Double) -> some View {
        let millimeters = Binding(get: { value.wrappedValue * 1_000 },
                                  set: { value.wrappedValue = $0 / 1_000 })
        return valueSlider(title, value: millimeters, range: range, step: step, unit: "mm")
    }

    private func valueSlider(_ title: LocalizedStringKey, value: Binding<Double>,
                             range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        // Valid settings restored from storage may lie outside the usual slider
        // range. Include that value without silently changing it on presentation.
        let visibleRange = min(range.lowerBound, value.wrappedValue)...max(range.upperBound, value.wrappedValue)
        let number = value.wrappedValue.formatted(.number.precision(.fractionLength(step < 1 ? 2 : 0)).locale(locale))
        let displayValue = unit.isEmpty ? number : "\(number) \(unit)"
        return VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(title).fixedSize()
                    Spacer(minLength: 8)
                    Text(verbatim: displayValue)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(ScanTheme.secondary)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: displayValue)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(ScanTheme.secondary)
                }
            }
            Slider(value: value, in: visibleRange, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(Text(verbatim: displayValue))
        }
        .padding(.vertical, 4)
    }
}

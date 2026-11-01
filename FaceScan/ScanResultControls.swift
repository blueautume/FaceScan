import SwiftUI

/// Result-only sizing. New scans and newly opened originals start at 1×.
struct ScanPointSizeControl: View {
    let title: LocalizedStringKey
    @Binding var scale: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(title).fixedSize()
            Slider(value: safeScale, in: 0.25...4, step: 0.05)
                .accessibilityLabel(title)
                .accessibilityValue("\(safeScale.wrappedValue, specifier: "%.2f") times")
                .accessibilityIdentifier("pointSize.result")
            Menu {
                ForEach([0.25, 0.5, 1, 1.5, 2, 3, 4], id: \.self) { value in
                    Button {
                        scale = value
                    } label: {
                        if value == safeScale.wrappedValue {
                            Label("\(value, specifier: "%.2f")×", systemImage: "checkmark")
                        } else {
                            Text("\(value, specifier: "%.2f")×")
                        }
                    }
                }
            } label: {
                Text("\(safeScale.wrappedValue, specifier: "%.2f")×")
                    .monospacedDigit()
                    .fixedSize()
                    .frame(minHeight: 44)
            }
            .accessibilityLabel("Choose a point size preset.")
            .accessibilityValue("\(safeScale.wrappedValue, specifier: "%.2f") times")
            Button("Reset") { scale = 1 }
                .frame(minHeight: 44)
                .accessibilityLabel("Reset point size to the default.")
        }
        .font(.system(size: 13, weight: .medium))
        .tint(ScanTheme.tint)
    }

    private var safeScale: Binding<Double> {
        Binding(get: { scale.isFinite ? min(4, max(0.25, scale)) : 1 },
                set: { scale = $0.isFinite ? min(4, max(0.25, $0)) : 1 })
    }
}

struct ScanResultComparisonButton: View {
    let isFiltered: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: "camera.filters")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isFiltered ? ScanTheme.primary : ScanTheme.canvasText)
                .frame(width: 48, height: 48)
                .background(isFiltered ? ScanTheme.accent : ScanTheme.canvasOverlay, in: Circle())
                .overlay {
                    Circle().stroke(isFiltered ? ScanTheme.accent : ScanTheme.canvasTrack, lineWidth: 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFiltered ? String(localized: "Show Original") : String(localized: "Show Filtered"))
        .accessibilityValue(isFiltered ? String(localized: "Showing filtered point cloud.") : String(localized: "Showing original point cloud."))
        .accessibilityAddTraits(isFiltered ? .isSelected : [])
        .accessibilityIdentifier("scan.resultComparison")
    }
}

/// Actual algorithm progress is shown inside the action; tapping it cancels work.
struct ScanFilterActionButton: View {
    let isFiltering: Bool
    let progress: Double
    let onApply: () -> Void
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double { progress.isFinite ? min(1, max(0, progress)) : 0 }
    private var percentage: Int { Int((fraction * 100).rounded(.down)) }

    var body: some View {
        Button(action: isFiltering ? onCancel : onApply) {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    if isFiltering {
                        Text("Filtering")
                        Spacer(minLength: 0)
                        Text("\(percentage)%")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .contentTransition(.numericText())
                    } else {
                        Label("Filter", systemImage: "camera.filters")
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                if isFiltering {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(ScanTheme.tint)
                        .animation(reduceMotion ? nil : .linear(duration: 0.15), value: fraction)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(ScanPrimaryButton())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isFiltering ? String(localized: "Cancel Filtering") : String(localized: "Filter"))
        .accessibilityValue(isFiltering ? String(localized: "\(percentage)% complete") : "")
        .accessibilityHint(isFiltering ? String(localized: "Filtering in progress. Double-tap to cancel.") : String(localized: "Filter the original scan using the current settings."))
        .accessibilityIdentifier("filter.apply")
    }
}

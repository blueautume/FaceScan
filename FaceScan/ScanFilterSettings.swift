import Foundation

/// Editable filter parameters use meters, matching the supplied processor.
/// The settings view converts lengths to millimeters for display only.
struct ScanFilterSettings: Codable, Equatable, Sendable {
    var sorNeighbors = 20
    var sorStandardDeviations = 2.5
    var cylinderCenterX = 0.0
    var cylinderCenterZ = -0.05
    var referenceRadius = 0.10
    var parameterGridSize = 0.0015
    var medianWindow = 5
    var minimumMedianObservations = 5
    var bilateralIterations = 3
    var bilateralHalfWindow = 4
    var bilateralSpatialSigma = 0.003
    var bilateralRadiusSigma = 0.006
    var colorRadialGate = 0.004
    var colorSpatialSigma = 0.0015
    var colorRGBSigma = 25.0
    var colorHalfWindow = 2
    var maximumRadialDisplacement = 0.015
    var filterColors = true

    static let storageKey = "FaceScan.filter.settings.v1"
    static let reference = ScanFilterSettings()

    /// A starting point for preserving detail, rather than an accuracy guarantee.
    static let gentle: ScanFilterSettings = {
        var settings = ScanFilterSettings.reference
        settings.sorStandardDeviations = 3.5
        settings.parameterGridSize = 0.00075
        settings.medianWindow = 1
        settings.minimumMedianObservations = 1
        settings.bilateralIterations = 1
        settings.bilateralHalfWindow = 2
        settings.bilateralSpatialSigma = 0.0015
        settings.bilateralRadiusSigma = 0.002
        settings.colorSpatialSigma = 0.00075
        settings.colorRGBSigma = 15
        settings.colorHalfWindow = 1
        settings.filterColors = false
        return settings
    }()

    var configuration: FaceCloudConfiguration {
        var value = FaceCloudConfiguration.reference
        value.sorNeighbors = sorNeighbors
        value.sorStandardDeviations = sorStandardDeviations
        value.cylinderCenterX = cylinderCenterX
        value.cylinderCenterZ = cylinderCenterZ
        value.referenceRadius = referenceRadius
        value.parameterGridSize = parameterGridSize
        value.medianWindow = medianWindow
        value.minimumMedianObservations = minimumMedianObservations
        value.bilateralIterations = bilateralIterations
        value.bilateralHalfWindow = bilateralHalfWindow
        value.bilateralSpatialSigma = bilateralSpatialSigma
        value.bilateralRadiusSigma = bilateralRadiusSigma
        value.colorRadialGate = colorRadialGate
        value.colorSpatialSigma = colorSpatialSigma
        value.colorRGBSigma = colorRGBSigma
        value.colorHalfWindow = colorHalfWindow
        value.maximumRadialDisplacement = maximumRadialDisplacement
        value.filterColors = filterColors
        return value
    }

    /// Mirrors the processor's parameter validation. The processor separately
    /// checks grid size against the actual scan and its unchanged memory cap.
    var isValid: Bool {
        let positive = [referenceRadius, parameterGridSize, bilateralSpatialSigma,
                        bilateralRadiusSigma, colorSpatialSigma, colorRGBSigma]
        let nonnegative = [sorStandardDeviations, colorRadialGate, maximumRadialDisplacement]
        guard positive.allSatisfy({ $0.isFinite && $0 > 0 }),
              nonnegative.allSatisfy({ $0.isFinite && $0 >= 0 }),
              cylinderCenterX.isFinite, cylinderCenterZ.isFinite,
              (1...1024).contains(sorNeighbors), (1...31).contains(medianWindow),
              !medianWindow.isMultiple(of: 2),
              (1...(medianWindow * medianWindow)).contains(minimumMedianObservations),
              (0...32).contains(bilateralIterations), (0...15).contains(bilateralHalfWindow),
              (0...15).contains(colorHalfWindow) else { return false }
        return true
    }

    static func load(from defaults: UserDefaults = .standard) -> ScanFilterSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(ScanFilterSettings.self, from: data),
              settings.isValid else { return .gentle }
        return settings
    }

    /// Invalid drafts never replace a previously saved valid configuration.
    func save(to defaults: UserDefaults = .standard) {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

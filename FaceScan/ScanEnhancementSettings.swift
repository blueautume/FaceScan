import Foundation

/// Display interpolation is separate from measured and filtered scan data.
/// Lengths are meters; the settings sheet displays millimeters.
struct ScanEnhancementSettings: Codable, Equatable, Sendable {
    var targetSpacing: Float = 0.0008
    var supportRadius: Float = 0.004
    var maximumGap: Float = 0.003
    var edgeProtection: Float = 0.7
    var colorTolerance: Float = 60
    var maximumPointCount = 200_000
    var seed: UInt64 = 0xFACE5CA1

    static let storageKey = "FaceScan.display.enhancement.v1"

    var isValid: Bool {
        targetSpacing.isFinite && (0.0002...0.005).contains(targetSpacing)
            && supportRadius.isFinite && (0.001...0.02).contains(supportRadius)
            && maximumGap.isFinite && (0.0005...0.012).contains(maximumGap)
            && edgeProtection.isFinite && (0...1).contains(edgeProtection)
            && colorTolerance.isFinite && (0...442).contains(colorTolerance)
            && (1...400_000).contains(maximumPointCount)
    }

    static func load(from defaults: UserDefaults = .standard) -> ScanEnhancementSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(Self.self, from: data),
              settings.isValid else { return Self() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// Live and completed point sizes are independent display preferences.
struct ScanDisplayPreferences: Codable, Equatable, Sendable {
    var livePointSizeScale = 1.0
    var resultPointSizeScale = 1.0

    static let storageKey = "FaceScan.display.pointSize.v1"

    var isValid: Bool {
        livePointSizeScale.isFinite && (0.25...4).contains(livePointSizeScale)
            && resultPointSizeScale.isFinite && (0.25...4).contains(resultPointSizeScale)
    }

    static func load(from defaults: UserDefaults = .standard) -> ScanDisplayPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let preferences = try? JSONDecoder().decode(Self.self, from: data),
              preferences.isValid else { return Self() }
        return preferences
    }

    func save(to defaults: UserDefaults = .standard) {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

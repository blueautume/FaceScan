import Foundation
import XCTest
@testable import FaceScan

final class ScanFilterSettingsTests: XCTestCase {
    func testReferenceMapsEveryProcessorParameterWithoutChangingMemoryCap() {
        assertConfiguration(ScanFilterSettings.reference.configuration, equals: .reference)
        XCTAssertTrue(ScanFilterSettings.reference.isValid)
        XCTAssertNil(ScanFilterSettings.reference.smoothingCurve)
        XCTAssertNil(ScanFilterSettings.gentle.smoothingCurve)
    }

    func testGentlePresetDisablesSpatialMedianAndColorFiltering() {
        let settings = ScanFilterSettings.gentle
        XCTAssertTrue(settings.isValid)
        XCTAssertEqual(settings.medianWindow, 1)
        XCTAssertEqual(settings.minimumMedianObservations, 1)
        XCTAssertEqual(settings.parameterGridSize, 0.00075)
        XCTAssertEqual(settings.bilateralIterations, 1)
        XCTAssertEqual(settings.bilateralRadiusSigma, 0.002)
        XCTAssertFalse(settings.filterColors)
        XCTAssertEqual(settings.configuration.cylinderCenterZ, -0.05)
        XCTAssertEqual(settings.configuration.maximumRadialDisplacement, 0.015)
    }

    func testStandardPresetMatchesRequestedMedianAndSmoothingProfile() throws {
        let settings = ScanFilterSettings.standard
        XCTAssertTrue(settings.isValid)
        XCTAssertEqual(settings.sorNeighbors, 20)
        XCTAssertEqual(settings.sorStandardDeviations, 3.5)
        XCTAssertEqual(settings.parameterGridSize, 0.00075)
        XCTAssertEqual(settings.medianWindow, 3)
        XCTAssertEqual(settings.minimumMedianObservations, 1)
        XCTAssertEqual(settings.bilateralIterations, 1)
        XCTAssertEqual(settings.bilateralHalfWindow, 2)
        XCTAssertEqual(settings.bilateralSpatialSigma, 0.0015)
        XCTAssertEqual(settings.bilateralRadiusSigma, 0.002)
        XCTAssertEqual(settings.maximumRadialDisplacement, 0.015)
        XCTAssertFalse(settings.filterColors)
        let curve = try XCTUnwrap(settings.smoothingCurve)
        XCTAssertEqual(curve.strengths, [1, 1, 1, 0.85, 0.48])
        XCTAssertEqual(curve.maximumVariation, 0.0035)
        XCTAssertEqual(curve.neighborhoodRadius, 0.004)
        XCTAssertEqual(curve.strength(for: 0.00175), 1)
        XCTAssertEqual(curve.strength(for: 0.0035), 0.48)

        var unchangedBase = settings
        unchangedBase.medianWindow = ScanFilterSettings.gentle.medianWindow
        unchangedBase.smoothingCurve = nil
        XCTAssertEqual(unchangedBase, .gentle, "All undisplayed parameters retain the detail-preserving base.")
        var expectedConfiguration = ScanFilterSettings.gentle.configuration
        expectedConfiguration.medianWindow = 3
        expectedConfiguration.smoothingCurve = curve
        assertConfiguration(settings.configuration, equals: expectedConfiguration)
    }

    func testCustomParametersRemainInMetersThroughConfigurationAndPersistence() throws {
        let suiteName = "FaceScan-filter-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var settings = ScanFilterSettings.reference
        settings.parameterGridSize = 0.0008
        settings.bilateralSpatialSigma = 0.0012
        settings.bilateralRadiusSigma = 0.0018
        settings.colorRadialGate = 0.0025
        settings.colorSpatialSigma = 0.0009
        settings.maximumRadialDisplacement = 0.025
        settings.cylinderCenterX = 0.003
        settings.cylinderCenterZ = -0.045
        settings.referenceRadius = 0.09
        settings.filterColors = false
        settings.save(to: defaults)

        let restored = ScanFilterSettings.load(from: defaults)
        XCTAssertEqual(restored, settings)
        XCTAssertEqual(restored.configuration.parameterGridSize, 0.0008)
        XCTAssertEqual(restored.configuration.maximumRadialDisplacement, 0.025)
        assertConfiguration(restored.configuration, equals: settings.configuration)
    }

    func testMissingMalformedAndInvalidSavedSettingsFallBackToStandard() throws {
        let suiteName = "FaceScan-filter-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .standard)
        defaults.set(Data("broken JSON".utf8), forKey: ScanFilterSettings.storageKey)
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .standard)
        var invalid = ScanFilterSettings.reference
        invalid.medianWindow = 2
        defaults.set(try JSONEncoder().encode(invalid), forKey: ScanFilterSettings.storageKey)
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .standard)
        invalid = .reference
        invalid.parameterGridSize = -1
        defaults.set(try JSONEncoder().encode(invalid), forKey: ScanFilterSettings.storageKey)
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .standard)
    }

    func testLegacyGentleDefaultUpgradesOnceWithoutDeletingLegacyBytes() throws {
        let suiteName = "FaceScan-filter-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyData = try JSONEncoder().encode(ScanFilterSettings.gentle)
        defaults.set(legacyData, forKey: ScanFilterSettings.legacyStorageKey)

        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .standard)
        XCTAssertEqual(defaults.data(forKey: ScanFilterSettings.legacyStorageKey), legacyData)
        let upgraded = try JSONDecoder().decode(ScanFilterSettings.self,
                                               from: XCTUnwrap(defaults.data(forKey: ScanFilterSettings.storageKey)))
        XCTAssertEqual(upgraded, .standard)

        var custom = ScanFilterSettings.standard
        custom.smoothingCurve?.strengths[4] = 0.37
        custom.medianWindow = 5
        custom.save(to: defaults)
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), custom,
                       "Later launches must retain changes made after the one-time migration.")
    }

    func testIntentionalLegacyReferenceSelectionRemainsReference() throws {
        let suiteName = "FaceScan-filter-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(try JSONEncoder().encode(ScanFilterSettings.reference),
                     forKey: ScanFilterSettings.legacyStorageKey)

        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .reference)
        XCTAssertNotNil(defaults.data(forKey: ScanFilterSettings.storageKey))
    }

    func testInvalidLegacySettingsUseStandardAndDamagedCurrentSettingsDoNotReviveLegacy() throws {
        let suiteName = "FaceScan-filter-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var invalid = ScanFilterSettings.gentle
        invalid.medianWindow = 2
        defaults.set(try JSONEncoder().encode(invalid), forKey: ScanFilterSettings.legacyStorageKey)
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .standard)

        defaults.set(try JSONEncoder().encode(ScanFilterSettings.reference),
                     forKey: ScanFilterSettings.legacyStorageKey)
        defaults.set(Data("broken JSON".utf8), forKey: ScanFilterSettings.storageKey)
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .standard,
                       "An older profile must not reappear when newer preferences are damaged.")
        defaults.set(true, forKey: ScanFilterSettings.storageKey)
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .standard)
    }

    func testCurrentSettingsAreNotReplacedByLegacyDefaultMigration() throws {
        let suiteName = "FaceScan-filter-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(try JSONEncoder().encode(ScanFilterSettings.reference),
                     forKey: ScanFilterSettings.legacyStorageKey)
        ScanFilterSettings.gentle.save(to: defaults)

        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .gentle,
                       "The old preset remains a valid explicit selection in the new format.")
    }

    func testCustomSettingsSurviveRepeatedLoadsAndSaves() throws {
        let suiteName = "FaceScan-filter-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyData = try JSONEncoder().encode(ScanFilterSettings.reference)
        defaults.set(legacyData, forKey: ScanFilterSettings.legacyStorageKey)
        var custom = ScanFilterSettings.standard
        custom.medianWindow = 5
        custom.parameterGridSize = 0.001
        custom.filterColors = true
        custom.smoothingCurve = FaceCloudSmoothingCurve(
            strengths: [0.95, 0.8, 0.55, 0.3, 0.1],
            maximumVariation: 0.006,
            neighborhoodRadius: 0.0055)
        custom.save(to: defaults)

        for _ in 0..<3 {
            let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            let restored = ScanFilterSettings.load(from: reopenedDefaults)
            XCTAssertEqual(restored, custom, "Opening settings again must retain the user's complete profile.")
            restored.save(to: reopenedDefaults)
        }
        XCTAssertEqual(defaults.data(forKey: ScanFilterSettings.legacyStorageKey), legacyData)
    }

    func testSavedExplicitResetRemainsStandardAcrossLoadsWithoutRevivingLegacyCustomSettings() throws {
        let suiteName = "FaceScan-filter-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var legacyCustom = ScanFilterSettings.reference
        legacyCustom.sorNeighbors = 32
        let legacyData = try JSONEncoder().encode(legacyCustom)
        defaults.set(legacyData, forKey: ScanFilterSettings.legacyStorageKey)
        var currentCustom = ScanFilterSettings.standard
        currentCustom.medianWindow = 7
        currentCustom.smoothingCurve?.strengths[4] = 0.2
        currentCustom.save(to: defaults)
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), currentCustom)

        // The reset action saves the standard profile; it does not remove v2,
        // because removing that key would allow old v1 preferences to return.
        ScanFilterSettings.standard.save(to: defaults)
        for _ in 0..<3 {
            let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            let restored = ScanFilterSettings.load(from: reopenedDefaults)
            XCTAssertEqual(restored, .standard)
            restored.save(to: reopenedDefaults)
        }
        XCTAssertNotNil(defaults.data(forKey: ScanFilterSettings.storageKey))
        XCTAssertEqual(defaults.data(forKey: ScanFilterSettings.legacyStorageKey), legacyData)
    }

    func testInvalidDraftDoesNotOverwriteSavedSettingsAndValidationHandlesExtremeIntegers() throws {
        let suiteName = "FaceScan-filter-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        ScanFilterSettings.reference.save(to: defaults)
        var invalid = ScanFilterSettings.gentle
        invalid.medianWindow = Int.max
        XCTAssertFalse(invalid.isValid, "Validate bounds before multiplying the window size.")
        invalid.save(to: defaults)
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .reference)
        invalid = .reference
        invalid.minimumMedianObservations = 26
        XCTAssertFalse(invalid.isValid)
        invalid = .reference
        invalid.bilateralRadiusSigma = .nan
        XCTAssertFalse(invalid.isValid)
    }

    func testLegacyParametersWithoutCurvePreserveCustomValues() throws {
        let suiteName = "FaceScan-filter-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var expected = ScanFilterSettings.reference
        expected.sorNeighbors = 28
        expected.parameterGridSize = 0.00125
        expected.bilateralIterations = 2
        expected.maximumRadialDisplacement = 0.021
        expected.filterColors = false
        var encoded = expected
        encoded.smoothingCurve = .featurePreserving
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(encoded)) as? [String: Any])
        XCTAssertNotNil(legacy.removeValue(forKey: "smoothingCurve"))
        let data = try JSONSerialization.data(withJSONObject: legacy)
        defaults.set(data, forKey: ScanFilterSettings.legacyStorageKey)

        let decoded = try JSONDecoder().decode(ScanFilterSettings.self, from: data)
        XCTAssertEqual(decoded, expected)
        XCTAssertNil(decoded.smoothingCurve, "Existing saved settings must keep curve filtering disabled.")
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), expected,
                       "Migration must not silently replace custom parameters with a preset.")
        XCTAssertEqual(defaults.data(forKey: ScanFilterSettings.legacyStorageKey), data)
        let migrated = try JSONDecoder().decode(ScanFilterSettings.self,
                                               from: XCTUnwrap(defaults.data(forKey: ScanFilterSettings.storageKey)))
        XCTAssertEqual(migrated, expected)
    }

    func testCurveParametersPersistAndMapWithoutChangingUnits() throws {
        let suiteName = "FaceScan-filter-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var settings = ScanFilterSettings.gentle
        var curve = FaceCloudSmoothingCurve.featurePreserving
        curve.strengths = [1, 0.9, 0.45, 0.1, 0]
        curve.maximumVariation = 0.0045
        curve.neighborhoodRadius = 0.0035
        settings.smoothingCurve = curve
        XCTAssertTrue(settings.isValid)
        settings.save(to: defaults)

        let restored = ScanFilterSettings.load(from: defaults)
        XCTAssertEqual(restored, settings)
        XCTAssertEqual(restored.configuration.smoothingCurve, curve)
        XCTAssertEqual(restored.configuration.smoothingCurve?.maximumVariation, 0.0045)
        XCTAssertEqual(restored.configuration.smoothingCurve?.neighborhoodRadius, 0.0035)
        assertConfiguration(restored.configuration, equals: settings.configuration)
    }

    func testInvalidCurveFallsBackAndCannotOverwriteValidSavedParameters() throws {
        let suiteName = "FaceScan-filter-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var saved = ScanFilterSettings.gentle
        saved.smoothingCurve = .featurePreserving
        saved.save(to: defaults)

        var invalid = saved
        invalid.smoothingCurve?.strengths = [1, 0.8, -0.1, 0.1, 0]
        XCTAssertFalse(invalid.isValid)
        invalid.save(to: defaults)
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), saved)

        defaults.set(try JSONEncoder().encode(invalid), forKey: ScanFilterSettings.storageKey)
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .standard)
        invalid = saved
        invalid.smoothingCurve?.maximumVariation = 0
        XCTAssertFalse(invalid.isValid)
        invalid = saved
        invalid.smoothingCurve?.strengths = [1, 0]
        XCTAssertFalse(invalid.isValid)
    }

    private func assertConfiguration(_ actual: FaceCloudConfiguration, equals expected: FaceCloudConfiguration,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.sorNeighbors, expected.sorNeighbors, file: file, line: line)
        XCTAssertEqual(actual.sorStandardDeviations, expected.sorStandardDeviations, file: file, line: line)
        XCTAssertEqual(actual.cylinderCenterX, expected.cylinderCenterX, file: file, line: line)
        XCTAssertEqual(actual.cylinderCenterZ, expected.cylinderCenterZ, file: file, line: line)
        XCTAssertEqual(actual.referenceRadius, expected.referenceRadius, file: file, line: line)
        XCTAssertEqual(actual.parameterGridSize, expected.parameterGridSize, file: file, line: line)
        XCTAssertEqual(actual.medianWindow, expected.medianWindow, file: file, line: line)
        XCTAssertEqual(actual.minimumMedianObservations, expected.minimumMedianObservations, file: file, line: line)
        XCTAssertEqual(actual.bilateralIterations, expected.bilateralIterations, file: file, line: line)
        XCTAssertEqual(actual.bilateralHalfWindow, expected.bilateralHalfWindow, file: file, line: line)
        XCTAssertEqual(actual.bilateralSpatialSigma, expected.bilateralSpatialSigma, file: file, line: line)
        XCTAssertEqual(actual.bilateralRadiusSigma, expected.bilateralRadiusSigma, file: file, line: line)
        XCTAssertEqual(actual.colorRadialGate, expected.colorRadialGate, file: file, line: line)
        XCTAssertEqual(actual.colorSpatialSigma, expected.colorSpatialSigma, file: file, line: line)
        XCTAssertEqual(actual.colorRGBSigma, expected.colorRGBSigma, file: file, line: line)
        XCTAssertEqual(actual.colorHalfWindow, expected.colorHalfWindow, file: file, line: line)
        XCTAssertEqual(actual.maximumRadialDisplacement, expected.maximumRadialDisplacement, file: file, line: line)
        XCTAssertEqual(actual.filterColors, expected.filterColors, file: file, line: line)
        XCTAssertEqual(actual.smoothingCurve, expected.smoothingCurve, file: file, line: line)
        XCTAssertEqual(actual.maximumGridCells, expected.maximumGridCells, file: file, line: line)
    }
}

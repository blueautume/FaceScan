import Foundation
import XCTest
@testable import FaceScan

final class ScanEnhancementSettingsTests: XCTestCase {
    func testDefaultsAreValidAndUseMeters() {
        let settings = ScanEnhancementSettings()
        XCTAssertTrue(settings.isValid)
        XCTAssertEqual(settings.targetSpacing, 0.0008)
        XCTAssertEqual(settings.resolutionMultiplier, 4)
        XCTAssertEqual(settings.supportRadius, 0.004)
        XCTAssertEqual(settings.maximumGap, 0.003)
        XCTAssertEqual(settings.edgeProtection, 0.7)
        XCTAssertEqual(settings.maximumPointCount, 200_000)
        XCTAssertEqual(settings.seed, 0xFACE5CA1)
        XCTAssertTrue(ScanDisplayPreferences().isValid)
    }

    func testCustomEnhancementParametersRoundTripWithoutChangingUnitsOrSeed() throws {
        try withDefaults { defaults in
            var settings = ScanEnhancementSettings()
            settings.targetSpacing = 0.0012
            settings.resolutionMultiplier = 8
            settings.supportRadius = 0.006
            settings.maximumGap = 0.0045
            settings.edgeProtection = 0.9
            settings.colorTolerance = 35
            settings.maximumPointCount = 300_000
            settings.seed = 123_456
            settings.save(to: defaults)
            let restored = ScanEnhancementSettings.load(from: defaults)
            XCTAssertEqual(restored, settings)
            XCTAssertEqual(restored.maximumGap, 0.0045)
            XCTAssertEqual(restored.resolutionMultiplier, 8)
            XCTAssertEqual(restored.seed, 123_456)
        }
    }

    func testMissingMalformedAndInvalidEnhancementStorageFallsBackToDefaults() throws {
        try withDefaults { defaults in
            XCTAssertEqual(ScanEnhancementSettings.load(from: defaults), ScanEnhancementSettings())
            defaults.set(Data("bad data".utf8), forKey: ScanEnhancementSettings.storageKey)
            XCTAssertEqual(ScanEnhancementSettings.load(from: defaults), ScanEnhancementSettings())
            var invalid = ScanEnhancementSettings()
            invalid.targetSpacing = -1
            defaults.set(try JSONEncoder().encode(invalid), forKey: ScanEnhancementSettings.storageKey)
            XCTAssertEqual(ScanEnhancementSettings.load(from: defaults), ScanEnhancementSettings())
        }
    }

    func testInvalidDraftCannotReplaceSavedEnhancementParameters() throws {
        try withDefaults { defaults in
            var saved = ScanEnhancementSettings()
            saved.edgeProtection = 0.95
            saved.save(to: defaults)
            var invalid = saved
            invalid.supportRadius = .nan
            XCTAssertFalse(invalid.isValid)
            invalid.save(to: defaults)
            XCTAssertEqual(ScanEnhancementSettings.load(from: defaults), saved)
            invalid = saved
            invalid.targetSpacing = 0
            XCTAssertFalse(invalid.isValid)
            invalid = saved
            invalid.maximumGap = .infinity
            XCTAssertFalse(invalid.isValid)
            invalid = saved
            invalid.edgeProtection = 1.1
            XCTAssertFalse(invalid.isValid)
            invalid = saved
            invalid.colorTolerance = -1
            XCTAssertFalse(invalid.isValid)
            invalid = saved
            invalid.maximumPointCount = 400_001
            XCTAssertFalse(invalid.isValid)
            invalid.maximumPointCount = 1
            XCTAssertTrue(invalid.isValid, "Small valid budgets allow interpolation to stop before adding any points.")
        }
    }

    func testLiveAndResultPointSizesPersistIndependently() throws {
        try withDefaults { defaults in
            var preferences = ScanDisplayPreferences()
            preferences.livePointSizeScale = 0.4
            preferences.resultPointSizeScale = 3.2
            preferences.save(to: defaults)
            XCTAssertEqual(ScanDisplayPreferences.load(from: defaults), preferences)
            preferences.livePointSizeScale = 1.8
            preferences.save(to: defaults)
            let restored = ScanDisplayPreferences.load(from: defaults)
            XCTAssertEqual(restored.livePointSizeScale, 1.8)
            XCTAssertEqual(restored.resultPointSizeScale, 3.2)
        }
    }

    func testLegacyEnhancementParametersKeepSavedValuesAndGainFourTimesResolution() throws {
        try withDefaults { defaults in
            var expected = ScanEnhancementSettings()
            expected.targetSpacing = 0.0013
            expected.supportRadius = 0.006
            expected.maximumGap = 0.004
            expected.edgeProtection = 0.85
            expected.colorTolerance = 40
            expected.maximumPointCount = 300_000
            expected.seed = 987_654
            var encoded = expected
            encoded.resolutionMultiplier = 16
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(encoded)) as? [String: Any])
            XCTAssertNotNil(legacy.removeValue(forKey: "resolutionMultiplier"))
            let data = try JSONSerialization.data(withJSONObject: legacy)
            defaults.set(data, forKey: ScanEnhancementSettings.storageKey)

            XCTAssertEqual(try JSONDecoder().decode(ScanEnhancementSettings.self, from: data), expected)
            XCTAssertEqual(ScanEnhancementSettings.load(from: defaults), expected)

            legacy.removeValue(forKey: "supportRadius")
            let incomplete = try JSONSerialization.data(withJSONObject: legacy)
            XCTAssertThrowsError(try JSONDecoder().decode(ScanEnhancementSettings.self, from: incomplete),
                                 "Only the newly introduced field may be absent.")
            defaults.set(incomplete, forKey: ScanEnhancementSettings.storageKey)
            XCTAssertEqual(ScanEnhancementSettings.load(from: defaults), ScanEnhancementSettings())
        }
    }

    func testInvalidResolutionCannotOverwriteSavedSettingsAndStoredInvalidValuesFallBack() throws {
        try withDefaults { defaults in
            var saved = ScanEnhancementSettings()
            saved.resolutionMultiplier = 8
            saved.save(to: defaults)
            for value in [0.99, 16.01, Double.nan, Double.infinity] {
                var invalid = saved
                invalid.resolutionMultiplier = value
                XCTAssertFalse(invalid.isValid)
                invalid.save(to: defaults)
                XCTAssertEqual(ScanEnhancementSettings.load(from: defaults), saved)
            }
            for value in [1.0, 16] {
                var valid = saved
                valid.resolutionMultiplier = value
                XCTAssertTrue(valid.isValid)
            }
            var invalid = saved
            invalid.resolutionMultiplier = 20
            defaults.set(try JSONEncoder().encode(invalid), forKey: ScanEnhancementSettings.storageKey)
            XCTAssertEqual(ScanEnhancementSettings.load(from: defaults), ScanEnhancementSettings())

            var nullValue = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
            nullValue["resolutionMultiplier"] = NSNull()
            XCTAssertThrowsError(try JSONDecoder().decode(ScanEnhancementSettings.self,
                                                         from: JSONSerialization.data(withJSONObject: nullValue)))
        }
    }

    func testInvalidPointSizePreferencesFallBackAndNeverOverwriteSavedValues() throws {
        try withDefaults { defaults in
            let saved = ScanDisplayPreferences(livePointSizeScale: 0.25, resultPointSizeScale: 4)
            XCTAssertTrue(saved.isValid)
            saved.save(to: defaults)
            var invalid = saved
            invalid.livePointSizeScale = .nan
            XCTAssertFalse(invalid.isValid)
            invalid.save(to: defaults)
            XCTAssertEqual(ScanDisplayPreferences.load(from: defaults), saved)
            invalid = saved
            invalid.resultPointSizeScale = 4.01
            XCTAssertFalse(invalid.isValid)
            defaults.set(try JSONEncoder().encode(invalid), forKey: ScanDisplayPreferences.storageKey)
            XCTAssertEqual(ScanDisplayPreferences.load(from: defaults), ScanDisplayPreferences())
            defaults.set(Data("invalid".utf8), forKey: ScanDisplayPreferences.storageKey)
            XCTAssertEqual(ScanDisplayPreferences.load(from: defaults), ScanDisplayPreferences())
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "FaceScan-presentation-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}

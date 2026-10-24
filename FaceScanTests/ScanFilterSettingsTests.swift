import Foundation
import XCTest
@testable import FaceScan

final class ScanFilterSettingsTests: XCTestCase {
    func testReferenceMapsEveryProcessorParameterWithoutChangingMemoryCap() {
        assertConfiguration(ScanFilterSettings.reference.configuration, equals: .reference)
        XCTAssertTrue(ScanFilterSettings.reference.isValid)
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

    func testMissingMalformedAndInvalidSavedSettingsFallBackToGentle() throws {
        let suiteName = "FaceScan-filter-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .gentle)
        defaults.set(Data("broken JSON".utf8), forKey: ScanFilterSettings.storageKey)
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .gentle)
        var invalid = ScanFilterSettings.reference
        invalid.medianWindow = 2
        defaults.set(try JSONEncoder().encode(invalid), forKey: ScanFilterSettings.storageKey)
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .gentle)
        invalid = .reference
        invalid.parameterGridSize = -1
        defaults.set(try JSONEncoder().encode(invalid), forKey: ScanFilterSettings.storageKey)
        XCTAssertEqual(ScanFilterSettings.load(from: defaults), .gentle)
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
        XCTAssertEqual(actual.maximumGridCells, expected.maximumGridCells, file: file, line: line)
    }
}

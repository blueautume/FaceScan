import Foundation
import XCTest
@testable import FaceScan

final class LocalizationTests: XCTestCase {
    func testBothLanguagesAreBundledWithEnglishAsFallback() {
        XCTAssertTrue(Bundle.main.localizations.contains("en"))
        XCTAssertTrue(Bundle.main.localizations.contains("zh-Hans"))
        XCTAssertEqual(Bundle.main.developmentLocalization, "en")
    }

    func testEnglishCountsUseSingularAndPluralForms() throws {
        let bundle = try languageBundle("en")
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(L10n.pointCount(0, locale: locale, bundle: bundle), "0 points")
        XCTAssertEqual(L10n.pointCount(1, locale: locale, bundle: bundle), "1 point")
        XCTAssertEqual(L10n.pointCount(2, locale: locale, bundle: bundle), "2 points")
        XCTAssertEqual(L10n.frameCount(1, locale: locale, bundle: bundle), "1 frame")
        XCTAssertEqual(L10n.frameCount(20, locale: locale, bundle: bundle), "20 frames")
        XCTAssertEqual(L10n.scanCount(1, locale: locale, bundle: bundle), "1 scan")
        XCTAssertEqual(L10n.scanCount(2, locale: locale, bundle: bundle), "2 scans")
        XCTAssertEqual(String(localized: "\(1) cells", bundle: bundle, locale: locale), "1 cell")
        XCTAssertEqual(String(localized: "\(2) cells", bundle: bundle, locale: locale), "2 cells")
    }

    func testChineseCountsAndContextSpecificResetLabels() throws {
        let bundle = try languageBundle("zh-Hans")
        let locale = Locale(identifier: "zh_CN")
        XCTAssertEqual(L10n.pointCount(1, locale: locale, bundle: bundle), "1 个点")
        XCTAssertEqual(L10n.pointCount(24, locale: locale, bundle: bundle), "24 个点")
        XCTAssertEqual(L10n.frameCount(1, locale: locale, bundle: bundle), "1 帧")
        XCTAssertEqual(L10n.scanCount(2, locale: locale, bundle: bundle), "2 份扫描")
        XCTAssertEqual(String(localized: "\(2) cells", bundle: bundle, locale: locale), "2 格")
        XCTAssertEqual(String(localized: "Reset", bundle: bundle), "重置")
        XCTAssertEqual(String(localized: "filter.reset", defaultValue: "Reset", bundle: bundle), "重置参数")
        XCTAssertEqual(String(localized: "Cancel", bundle: bundle), "取消")
        XCTAssertEqual(String(localized: "filter.reset", defaultValue: "Reset", bundle: try languageBundle("en")), "Reset")
    }

    func testDynamicSubstitutionsPreserveDetailsInBothLanguages() throws {
        for language in ["en", "zh-Hans"] {
            let bundle = try languageBundle(language)
            let reason = "Disk full"
            let message = String(localized: "Couldn't load Scan History: \(reason)", bundle: bundle)
            XCTAssertTrue(message.contains(reason))
            XCTAssertFalse(message.contains("%@"))
            let percentage = 37
            let progress = String(localized: "\(percentage)% complete", bundle: bundle)
            XCTAssertTrue(progress.contains("37%"))
            XCTAssertFalse(progress.contains("%lld"))
            if language == "zh-Hans" {
                XCTAssertTrue(containsChinese(message))
                XCTAssertTrue(containsChinese(progress))
            }
        }
    }

    func testCameraPermissionAndFileTypeHaveLocalizedSystemResources() throws {
        for language in ["en", "zh-Hans"] {
            let bundle = try languageBundle(language)
            let camera = bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist")
            let model = bundle.localizedString(forKey: "PLY Model", value: nil, table: "InfoPlist")
            XCTAssertNotEqual(camera, "NSCameraUsageDescription")
            XCTAssertFalse(camera.isEmpty)
            XCTAssertEqual(model, language == "en" ? "PLY Model" : "PLY 模型")
            XCTAssertEqual(containsChinese(camera), language == "zh-Hans")
        }
    }

    @MainActor
    func testImperativeCaptureAndErrorTextFollowsTheAppLanguage() {
        let chinese = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        let scanner = FaceScanController(privacyConsent: PrivacyConsentStore())
        let strings = [scanner.hint,
                       ScanAngle.center.guidance, ScanAngle.chin.label,
                       ScanExporter.ExportError.emptyMesh.localizedDescription,
                       ScanPointCloudFilter.FilterError.emptyMesh.localizedDescription,
                       PLYImporter.ImportError.unreadableFile.localizedDescription,
                       FaceCloudProcessingError.noSupportedPoints.localizedDescription]
        for text in strings {
            XCTAssertEqual(containsChinese(text), chinese, "Unexpected app language: \(text)")
            XCTAssertFalse(text.contains("%@"))
        }
    }

    private func languageBundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    private func containsChinese(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }
}

import Foundation
import XCTest
@testable import FaceScan

final class PrivacyConsentStoreTests: XCTestCase {
    @MainActor
    func testFreshInstallRequiresConsentWithoutWritingPreferences() async throws {
        let suite = "FaceScanTests.privacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = PrivacyConsentStore(defaults: defaults)

        XCTAssertFalse(store.isAccepted)
        XCTAssertNil(defaults.object(forKey: PrivacyConsentStore.acceptedVersionKey))
    }

    @MainActor
    func testConsentPersistsForTheSamePolicyVersion() async throws {
        let suite = "FaceScanTests.privacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = PrivacyConsentStore(defaults: defaults, version: 3)
        store.accept()

        XCTAssertTrue(store.isAccepted)
        XCTAssertEqual(defaults.integer(forKey: PrivacyConsentStore.acceptedVersionKey), 3)
        XCTAssertTrue(PrivacyConsentStore(defaults: defaults, version: 3).isAccepted)
    }

    @MainActor
    func testChangedPolicyVersionRequiresFreshConsent() async throws {
        let suite = "FaceScanTests.privacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        PrivacyConsentStore(defaults: defaults, version: 1).accept()
        let updatedPolicy = PrivacyConsentStore(defaults: defaults, version: 2)

        XCTAssertFalse(updatedPolicy.isAccepted)
        updatedPolicy.accept()
        XCTAssertTrue(PrivacyConsentStore(defaults: defaults, version: 2).isAccepted)
        XCTAssertFalse(PrivacyConsentStore(defaults: defaults, version: 1).isAccepted)
    }

    @MainActor
    func testRevocationRemovesConsentAcrossRelaunches() async throws {
        let suite = "FaceScanTests.privacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("preserved", forKey: "unrelated-preference")
        let store = PrivacyConsentStore(defaults: defaults)
        store.accept()

        store.revoke()

        XCTAssertFalse(store.isAccepted)
        XCTAssertNil(defaults.object(forKey: PrivacyConsentStore.acceptedVersionKey))
        XCTAssertFalse(PrivacyConsentStore(defaults: defaults).isAccepted)
        XCTAssertEqual(defaults.string(forKey: "unrelated-preference"), "preserved")
    }
}

import Combine
import Foundation

/// Stores only the consent version in this app's local preferences.
/// A changed policy version requires fresh consent before camera preparation.
@MainActor
final class PrivacyConsentStore: ObservableObject {
    nonisolated static let currentVersion = 2
    nonisolated static let acceptedVersionKey = "FaceScan.privacy.acceptedVersion"

    @Published private(set) var isAccepted: Bool

    private let defaults: UserDefaults
    private let version: Int

    init(defaults: UserDefaults = .standard, version: Int = currentVersion) {
        precondition(version > 0, "The privacy policy version must be positive.")
        self.defaults = defaults
        self.version = version
        isAccepted = defaults.integer(forKey: Self.acceptedVersionKey) == version
    }

    func accept() {
        defaults.set(version, forKey: Self.acceptedVersionKey)
        isAccepted = true
    }

    /// The caller also stops capture and removes in-memory scan/export state.
    func revoke() {
        defaults.removeObject(forKey: Self.acceptedVersionKey)
        isAccepted = false
    }
}

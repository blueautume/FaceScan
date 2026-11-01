import Foundation

/// Shared plural forms used by visible metadata and VoiceOver. The catalog
/// keeps English singular/plural grammar separate from Chinese count labels.
enum L10n {
    static func pointCount(_ count: Int, locale: Locale = .current, bundle: Bundle = .main) -> String {
        String(localized: "\(count) points", bundle: bundle, locale: locale)
    }

    static func frameCount(_ count: Int, locale: Locale = .current, bundle: Bundle = .main) -> String {
        String(localized: "\(count) frames", bundle: bundle, locale: locale)
    }

    static func scanCount(_ count: Int, locale: Locale = .current, bundle: Bundle = .main) -> String {
        String(localized: "\(count) scans", bundle: bundle, locale: locale)
    }
}

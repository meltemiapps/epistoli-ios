import Foundation

/// Reads brand strings from Info.plist, which gets them from Config/Base.xcconfig.
/// Code must use `Brand` and never hard-code a brand string (scripts/brand_check.sh enforces this).
enum Brand {
    static var displayName: String {
        string(for: "CFBundleDisplayName")
    }

    /// The Latin-script name, for subtitles such as "<name> · private family messenger".
    static var asciiName: String {
        string(for: "BrandASCIIName")
    }

    static func string(for key: String, in bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: key) as? String ?? ""
    }
}

enum BrandGuard {
    /// Problems with the brand strings in the bundle; empty when all is well.
    static func problems(in bundle: Bundle = .main) -> [String] {
        var found: [String] = []
        for key in ["CFBundleDisplayName", "BrandASCIIName", "NSCameraUsageDescription"] {
            let value = Brand.string(for: key, in: bundle)
            if value.isEmpty { found.append("\(key) is missing") }
            if value.contains("$(") { found.append("\(key) has an unexpanded build setting: \(value)") }
        }
        let name = Brand.string(for: "CFBundleDisplayName", in: bundle)
        if !name.isEmpty, !Brand.string(for: "NSCameraUsageDescription", in: bundle).contains(name) {
            found.append("NSCameraUsageDescription does not mention the display name")
        }
        return found
    }

    static func verify(bundle: Bundle = .main) {
        let found = problems(in: bundle)
        assert(found.isEmpty, "BrandGuard: \(found.joined(separator: "; "))")
    }
}

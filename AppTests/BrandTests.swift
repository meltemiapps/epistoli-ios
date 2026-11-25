import Foundation
import Testing
@testable import Epistoli

@Suite struct BrandTests {
    @Test func displayNameIsGreek() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Επιστολή")
    }

    @Test func bundleIdentifier() {
        #expect(Bundle.main.bundleIdentifier == "com.meltemiapps.epistoli")
    }

    @Test func brandGuardFindsNoProblems() {
        #expect(BrandGuard.problems() == [])
    }

    @Test func cameraUsageDescription() {
        #expect(Brand.string(for: "NSCameraUsageDescription") == "Scan a family member's Επιστολή code to add their key")
    }

    @Test func declaresNonExemptEncryption() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool == true)
    }

    @Test func compatibilityModeNeverSet() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "UIDesignRequiresCompatibility") == nil)
    }
}

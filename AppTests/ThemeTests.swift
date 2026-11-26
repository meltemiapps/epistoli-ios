import SwiftUI
import Testing
import UIKit
@testable import Epistoli

/// WCAG contrast for the solid colours the theme puts text on. Text on glass is measured from
/// screenshots instead (scripts/contrast_check.swift), because glass depends on the background.
@Suite struct ThemeTests {
    @Test(arguments: BackgroundPreset.allCases)
    func accentFillCarriesWhiteText(preset: BackgroundPreset) {
        #expect(Contrast.ratio(.white, Contrast.darkened(preset.accent)) >= 4.5)
    }

    @Test func accentsThatAlreadyPassAreUnchanged() {
        for preset in [BackgroundPreset.olive, .night] {
            #expect(Contrast.darkened(preset.accent) == preset.accent)
        }
    }

    @Test func photoAccentFillCarriesWhiteText() {
        for hue in stride(from: 0.0, through: 1.0, by: 0.05) {
            let accent = UIColor(hue: hue, saturation: 0.65, brightness: 0.8, alpha: 1)
            #expect(Contrast.ratio(.white, Contrast.darkened(accent)) >= 4.5)
        }
    }

    @Test func badgesAreReadable() {
        #expect(Contrast.ratio(.badgeText, .badgeAmber) >= 4.5)
        #expect(Contrast.ratio(.badgeText, .badgeGreen) >= 4.5)
    }

    @Test func wcagReferenceValues() {
        #expect(abs(Contrast.ratio(.white, .black) - 21) < 0.01)
        #expect(abs(Contrast.ratio(.white, UIColor(hex: 0x767676)) - 4.54) < 0.01)
    }
}

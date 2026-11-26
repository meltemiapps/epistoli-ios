import Testing
import EpistoliCore
@testable import Epistoli

/// The chat's banner and attach sheet say only what is true for the chat and this build.
@Suite struct ChatCopyTests {
    @Test func bannerMatchesTheDemoWhenEveryKeyWasScanned() {
        #expect(PGPBanner(on: true, allVerified: true).text == "PGP on: only the people in this chat can read it. Keys checked by QR code.")
        #expect(PGPBanner(on: false, allVerified: true).text == "PGP off: protected in transit (TLS) and by your cloud provider, who could technically read it.")
    }

    @Test func bannerDoesNotClaimCheckedKeysForPastedCodes() {
        let text = PGPBanner(on: true, allVerified: false).text
        #expect(!text.contains("Keys checked"))
        #expect(text.contains("Scan their code in person"))
    }

    @Test func attachSheetOffersOnlyThisBuildsSources() {
        #expect(AttachSheet.sources.map(\.label) == ["Photos", "Files", "iCloud Drive"])
        // TODO(build 2): Google Drive joins the sheet with Features.googleDrive.
        #expect(!AttachSheet.sources.map(\.label).contains("Google Drive") || Features.googleDrive)
    }
}

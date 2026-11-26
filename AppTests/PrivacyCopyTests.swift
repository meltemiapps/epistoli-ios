import Testing
@testable import Epistoli

/// The Privacy card says only what this build does. When a feature ships, flip its flag in
/// Features.swift; these tests then expect its sentence back, exactly as in the approved demo.
@Suite struct PrivacyCopyTests {
    static let demoText = "PGP for new chats: on. You can switch it off per chat. Every message also travels over TLS. No accounts, analytics, ads or tracking. Nothing leaves your phone except to the people you message, through your own iCloud or Google Drive."

    @Test func everyFeatureOnIsTheDemoText() {
        #expect(PrivacyCopy.text(perChatPGPToggle: true, googleDrive: true) == Self.demoText)
    }

    @Test func thisBuildMentionsOnlyShippedFeatures() {
        let text = PrivacyCopy.text()
        #expect(text.contains("switch it off per chat") == Features.perChatPGPToggle)
        #expect(text.contains("Google Drive") == Features.googleDrive)
        #expect(text.hasSuffix("through your own iCloud.") || Features.googleDrive)
    }

    @Test func eachFeatureAddsOnlyItsOwnSentence() {
        #expect(PrivacyCopy.text(perChatPGPToggle: false, googleDrive: false) == "PGP for new chats: on. Every message also travels over TLS. No accounts, analytics, ads or tracking. Nothing leaves your phone except to the people you message, through your own iCloud.")
        #expect(PrivacyCopy.text(perChatPGPToggle: true, googleDrive: false).contains("You can switch it off per chat."))
        #expect(PrivacyCopy.text(perChatPGPToggle: false, googleDrive: true).hasSuffix("through your own iCloud or Google Drive."))
    }
}

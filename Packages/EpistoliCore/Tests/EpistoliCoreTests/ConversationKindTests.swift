import Testing
@testable import EpistoliCore

@Suite struct ConversationKindTests {
    @Test func rawValuesAreStable() {
        #expect(ConversationKind.allCases.map(\.rawValue) == ["direct", "group", "channel", "assistant"])
    }

    @Test func reservedKindsAreNotAvailableInV1() {
        #expect(!ConversationKind.channel.isAvailableInV1)
        #expect(!ConversationKind.assistant.isAvailableInV1)
        #expect(ConversationKind.direct.isAvailableInV1)
        #expect(ConversationKind.group.isAvailableInV1)
    }

    @Test func groupLimitIs32() {
        #expect(ConversationLimits.maxGroupMembers == 32)
    }

    @Test func fourBackgroundPresets() {
        #expect(BackgroundPreset.allCases.map(\.rawValue) == ["aegean", "sunset", "olive", "night"])
    }
}

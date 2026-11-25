/// The kind of a conversation. Stored as a raw string, so cases must never be renamed.
public enum ConversationKind: String, Codable, Sendable, CaseIterable {
    /// One-to-one chat.
    case direct
    /// Group chat, up to `ConversationLimits.maxGroupMembers` members.
    case group
    // v1.2 Programmable Channels, see docs/ROADMAP.md
    case channel
    // v1.2 Programmable Channels, see docs/ROADMAP.md
    case assistant

    /// Kinds the v1 app can create and show.
    public static let availableInV1: [ConversationKind] = [.direct, .group]

    public var isAvailableInV1: Bool { Self.availableInV1.contains(self) }
}

public enum ConversationLimits {
    public static let maxGroupMembers = 32
}

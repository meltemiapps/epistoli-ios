/// Features the UI may only mention once they ship. Copy that describes a feature reads these, so
/// nothing promises what this build can't do. AppTests/PrivacyCopyTests checks both states.
enum Features {
    /// The PGP chip in every chat header (section 4).
    static let perChatPGPToggle = true
    // TODO(build 2): set to true when Google Drive transport ships.
    static let googleDrive = false
}

/// Settings › Appearance › Privacy. With every feature on, this is the approved demo's text.
enum PrivacyCopy {
    static func text(perChatPGPToggle: Bool = Features.perChatPGPToggle,
                     googleDrive: Bool = Features.googleDrive) -> String {
        var parts = ["PGP for new chats: on."]
        if perChatPGPToggle { parts.append("You can switch it off per chat.") }
        parts.append("Every message also travels over TLS.")
        parts.append("No accounts, analytics, ads or tracking.")
        parts.append("Nothing leaves your phone except to the people you message, through your own iCloud\(googleDrive ? " or Google Drive" : "").")
        return parts.joined(separator: " ")
    }
}

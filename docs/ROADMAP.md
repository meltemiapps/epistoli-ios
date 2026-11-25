# Roadmap

- **v1.0**: one-to-one and group chat (up to 32 members), attachments, QR key exchange, optional per-chat OpenPGP, iCloud (CloudKit) transport. TestFlight build 2 adds Google Drive transport.
- **v1.1**: Siri and voice notes.
- **v1.2**: Programmable Channels and AI bots (`ConversationKind.channel` and `ConversationKind.assistant` are reserved for this).
- **France**: after launch, once an INPI trademark check is done (see `docs/TRADEMARK_AUDIT.md`).

## Before accepting outside contributions

- Publish `CLA.md`: a CLA based on the Apache Individual Contributor License Agreement v2.2, adapted for Meltemi Apps.

## Later options (not scheduled)

- Notification Service Extension that decrypts the message preview on the device. Until then, notifications show only a generic "New message" alert, never message content.

import CryptoKit
import Foundation
import OSLog
import EpistoliCore
import KeyExchange
import SealedCrypto

public struct OutgoingAttachment: Sendable {
    public var data: Data
    public var name: String
    public var mime: String
    public var source: AttachmentSource

    public init(data: Data, name: String, mime: String, source: AttachmentSource) {
        self.data = data
        self.name = name
        self.mime = mime
        self.source = source
    }
}

public enum MessagingError: Error, Equatable, Sendable {
    case emptyMessage
    case unknownConversation
    /// None of the chat's members is a contact any more.
    case noRecipients
    case groupTooLarge
    case attachmentTooLarge
}

/// What one pass over the mailbox did.
public struct ReceiveReport: Equatable, Sendable {
    /// New messages saved.
    public var received = 0
    /// Envelopes that failed their checks (bad signature, wrong key, damaged), set aside.
    public var rejected = 0
    /// Envelopes left in the mailbox: from someone who isn't a contact yet, or whose attachment
    /// hasn't arrived. They are tried again on the next pass.
    public var waiting = 0
    /// Conversations joined from invitations (CloudKit shares accepted).
    public var joined = 0

    public init() {}
}

/// Sends and receives messages for our identity. Format: docs/WIRE_FORMAT.md.
///
/// Every envelope is signed with our identity key. With PGP on (the default) it is also encrypted
/// to every recipient, so the transport and the cloud provider only see ciphertext. With PGP off it
/// is signed but readable by the provider, as the chat banner says.
public final class Messenger: Sendable {
    public let identity: Identity
    private let contacts: ContactStore
    private let store: ConversationStore
    private let transport: any Transport
    private let now: @Sendable () -> Date
    private static let log = Logger(subsystem: "Messaging", category: "messenger")

    public static let maxTitleLength = 64

    public init(identity: Identity, contacts: ContactStore, store: ConversationStore, transport: any Transport,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.identity = identity
        self.contacts = contacts
        self.store = store
        self.transport = transport
        self.now = now
    }

    // MARK: Conversations

    /// The one-to-one chat with `contact`, created (PGP on) if it doesn't exist yet.
    public func directConversation(with contact: Contact) throws -> Conversation {
        guard let id = ConversationID.direct(identity.address, contact.address) else { throw MessagingError.noRecipients }
        return try store.create(id, title: nil, members: [contact.address], now: now())
    }

    /// A new group with us and `members`. The others see it when the first message arrives.
    public func createGroup(title: String, members: [Contact]) throws -> Conversation {
        let addresses = Set(members.map(\.address)).subtracting([identity.address])
        guard !addresses.isEmpty else { throw MessagingError.noRecipients }
        guard addresses.count + 1 <= ConversationLimits.maxGroupMembers else { throw MessagingError.groupTooLarge }
        let name = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitleLength))
        guard !name.isEmpty else { throw MessagingError.emptyMessage }
        return try store.create(.newGroup(), title: name, members: Array(addresses), now: now())
    }

    // MARK: Sending

    @discardableResult
    public func send(text: String, in id: ConversationID) async throws -> ChatMessage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MessagingError.emptyMessage }
        return try await send(.text(trimmed), in: id)
    }

    /// Encrypts the attachment on this phone (PGP on), uploads it as a blob and sends a message naming it.
    @discardableResult
    public func send(attachment: OutgoingAttachment, in id: ConversationID) async throws -> ChatMessage {
        guard attachment.data.count <= AttachmentLimits.maxBytes else { throw MessagingError.attachmentTooLarge }
        let conversation = try conversation(id)
        let recipients = try recipients(of: conversation)
        let blobID = UUID()
        let blob = conversation.pgp
            ? try SealedCrypto.encrypt(attachment.data, to: recipients.map(\.key), signedBy: identity.privateKey)
            : attachment.data
        try await transport.prepare(id, recipients: recipients.map(\.address), seal: invitationSealer(for: recipients))
        try await transport.putBlob(blob, id: blobID, conversation: id)
        let name = String(attachment.name.prefix(200))
        let info = AttachmentInfo(blob: blobID, name: name.isEmpty ? "attachment" : name, mime: attachment.mime,
                                  size: attachment.data.count, source: attachment.source, blobSHA256: Self.sha256(blob))
        return try await send(.attachment(info), in: id, attachmentData: attachment.data)
    }

    /// Turns PGP on or off for the chat and tells the other members. The notice itself is always
    /// PGP-encrypted, so turning PGP off doesn't leak anything.
    @discardableResult
    public func setPGP(_ on: Bool, in id: ConversationID) async throws -> ChatMessage {
        try await send(.pgpSetting(on: on), in: id)
    }

    private func send(_ content: MessageContent, in id: ConversationID, attachmentData: Data? = nil) async throws -> ChatMessage {
        let conversation = try conversation(id)
        let recipients = try recipients(of: conversation)
        let pgp: Bool
        if case .pgpSetting = content { pgp = true } else { pgp = conversation.pgp }
        let message = ChatMessage(id: UUID(), conversation: id, sender: identity.address, outgoing: true,
                                  lamport: try store.nextLamport(in: id), sentAt: now(), pgp: pgp, content: content)
        let payload = Payload(id: message.id, from: identity.address, conversation: id,
                              group: try groupInfo(for: conversation), lamport: message.lamport, sentAt: message.sentAt, content: content)
        let envelope = try seal(payload, pgp: pgp, to: recipients.map(\.key))
        try await transport.prepare(id, recipients: recipients.map(\.address), seal: invitationSealer(for: recipients))
        try await transport.deliver(envelope, id: message.id, conversation: id, to: recipients.map(\.address))
        try store.insert(message, attachment: attachmentData, now: now())
        return message
    }

    private func seal(_ payload: Payload, pgp: Bool, to keys: [PGPPublicKey]) throws -> Data {
        let body = try payload.encoded()
        let envelope = pgp
            ? Envelope(id: payload.id, from: identity.address, mode: .pgp,
                       body: try SealedCrypto.encrypt(body, to: keys, signedBy: identity.privateKey))
            : Envelope(id: payload.id, from: identity.address, mode: .signed, body: body,
                       signature: try SealedCrypto.sign(body, with: identity.privateKey))
        return try envelope.encoded()
    }

    /// Seals an invitation for one recipient: encrypted to them alone and signed by us.
    private func invitationSealer(for recipients: [(address: TransportAddress, key: PGPPublicKey)])
        -> @Sendable (TransportAddress, Invitation) throws -> Data {
        let keys = Dictionary(recipients.map { ($0.address, $0.key) }, uniquingKeysWith: { a, _ in a })
        let me = identity
        return { address, invitation in
            guard let key = keys[address], invitation.from == me.address else { throw MessagingError.noRecipients }
            let body = try SealedCrypto.encrypt(invitation.encoded(), to: [key], signedBy: me.privateKey)
            return try Envelope(id: UUID(), from: me.address, mode: .pgp, body: body).encoded()
        }
    }

    private func conversation(_ id: ConversationID) throws -> Conversation {
        guard let conversation = try store.conversation(id) else { throw MessagingError.unknownConversation }
        return conversation
    }

    /// Members we can encrypt to: those who are contacts, with their current key.
    private func recipients(of conversation: Conversation) throws -> [(address: TransportAddress, key: PGPPublicKey)] {
        let byAddress = Dictionary(try contacts.all().map { ($0.address, $0) }, uniquingKeysWith: { a, _ in a })
        let list = try conversation.members.compactMap { address -> (TransportAddress, PGPPublicKey)? in
            guard let contact = byAddress[address] else { return nil }
            return (address, try PGPPublicKey(data: contact.currentKey.publicKey))
        }
        guard !list.isEmpty else { throw MessagingError.noRecipients }
        return list
    }

    private func groupInfo(for conversation: Conversation) throws -> GroupInfo? {
        guard conversation.kind == .group else { return nil }
        let byAddress = Dictionary(try contacts.all().map { ($0.address, $0) }, uniquingKeysWith: { a, _ in a })
        let others = conversation.members.compactMap { address in
            byAddress[address].map { GroupMember(address: address, name: $0.displayName, publicKey: $0.currentKey.publicKey) }
        }
        let me = GroupMember(address: identity.address, name: identity.displayName, publicKey: identity.publicKey.data)
        return GroupInfo(title: conversation.title ?? "", members: [me] + others)
    }

    // MARK: Receiving

    private enum Outcome { case received, joined, duplicate, rejected, waiting }

    /// One pass over our mailbox. Safe to call often; envelopes already processed are skipped.
    @discardableResult
    public func receive() async throws -> ReceiveReport {
        var report = try await receivePass()
        // Joining a conversation makes its messages fetchable: fetch them now, not on the next pass.
        if report.joined > 0 {
            let more = try await receivePass()
            report.received += more.received
            report.rejected += more.rejected
            report.joined += more.joined
            report.waiting = more.waiting
        }
        return report
    }

    private func receivePass() async throws -> ReceiveReport {
        var report = ReceiveReport()
        for item in try await transport.inbox() {
            let outcome: Outcome
            do {
                outcome = item.kind == .invitation ? try await processInvitation(item) : try await process(item)
            } catch {
                Self.log.error("Rejected envelope \(item.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
                outcome = .rejected
            }
            switch outcome {
            case .received: report.received += 1; try await transport.remove(item)
            case .joined: report.joined += 1; try await transport.remove(item)
            case .duplicate: try await transport.remove(item)
            case .rejected: report.rejected += 1; try await transport.reject(item)
            case .waiting: report.waiting += 1
            }
        }
        return report
    }

    /// Puts rejected envelopes back for another try: after a contact's new key is accepted, their
    /// messages signed with it can be read.
    public func retryRejected() async throws {
        try await transport.retryRejected()
    }

    /// An invitation must be a `pgp` envelope from a contact, signed with their current key, for a
    /// conversation that includes us. Joining only gives access to ciphertext: every message in the
    /// conversation is still checked by `process` like any other.
    private func processInvitation(_ item: InboxItem) async throws -> Outcome {
        let envelope = try Envelope.decode(item.data)
        guard envelope.mode == .pgp else { return .rejected }
        guard let sender = try contacts.all().first(where: { $0.address == envelope.from }) else { return .waiting }
        let body = try SealedCrypto.decrypt(envelope.body, with: identity.privateKey,
                                            verifyingSender: try PGPPublicKey(data: sender.currentKey.publicKey))
        let invitation = try Invitation.decode(body)
        guard invitation.v == Invitation.version, invitation.from == envelope.from else { return .rejected }
        switch invitation.conversation.kind {
        case .direct:
            guard Set(invitation.conversation.directMembers) == [identity.address, sender.address] else { return .rejected }
        case .group:
            break   // membership is checked on every message in it
        case .channel, .assistant:
            return .rejected
        }
        try await transport.join(invitation)
        return .joined
    }

    private func process(_ item: InboxItem) async throws -> Outcome {
        let envelope = try Envelope.decode(item.data)
        guard envelope.id == item.id else { return .rejected }
        if try store.hasMessage(envelope.id) { return .duplicate }
        let all = try contacts.all()
        // Only people we've added can message us. Anyone else's envelope waits until we add them.
        guard let sender = all.first(where: { $0.address == envelope.from }) else { return .waiting }
        let senderKey = try PGPPublicKey(data: sender.currentKey.publicKey)

        let body: Data
        switch envelope.mode {
        case .pgp:
            body = try SealedCrypto.decrypt(envelope.body, with: identity.privateKey, verifyingSender: senderKey)
        case .signed:
            try SealedCrypto.verify(envelope.body, signature: envelope.signature ?? Data(), by: senderKey)
            body = envelope.body
        }
        let payload = try Payload.decode(body)
        guard payload.v == Payload.version, payload.id == envelope.id, payload.from == envelope.from else { return .rejected }

        guard try accept(payload, from: sender, contacts: all) else { return .rejected }

        var attachmentData: Data?
        switch payload.content {
        case .text(let text):
            guard !text.isEmpty else { return .rejected }
        case .attachment(let info):
            guard info.size <= AttachmentLimits.maxBytes else { return .rejected }
            guard let blob = try await transport.blob(info.blob, route: item.route) else { return .waiting }
            guard Self.sha256(blob) == info.blobSHA256 else { return .rejected }
            let data = envelope.mode == .pgp
                ? try SealedCrypto.decrypt(blob, with: identity.privateKey, verifyingSender: senderKey)
                : blob
            guard data.count == info.size else { return .rejected }
            attachmentData = data
        case .pgpSetting:
            break
        }

        let message = ChatMessage(id: payload.id, conversation: payload.conversation, sender: sender.address, outgoing: false,
                                  lamport: payload.lamport, sentAt: payload.sentAt, pgp: envelope.mode == .pgp, content: payload.content)
        return try store.insert(message, attachment: attachmentData, now: now()) ? .received : .duplicate
    }

    /// Checks the message belongs in its conversation and creates the conversation on first sight.
    private func accept(_ payload: Payload, from sender: Contact, contacts all: [Contact]) throws -> Bool {
        let id = payload.conversation
        switch id.kind {
        case .direct:
            guard payload.group == nil, Set(id.directMembers) == [identity.address, sender.address] else { return false }
            try store.create(id, title: nil, members: [sender.address], now: now())
            return true
        case .group:
            if let existing = try store.conversation(id) {
                // Membership is fixed when the group is created; later lists are ignored.
                return existing.members.contains(sender.address)
            }
            guard let group = payload.group else { return false }
            let addresses = group.members.map(\.address)
            guard Set(addresses).count == addresses.count, addresses.count <= ConversationLimits.maxGroupMembers,
                  addresses.contains(identity.address), addresses.contains(sender.address) else { return false }
            let title = String(group.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitleLength))
            introduce(group.members, known: Set(all.map(\.address)))
            try store.create(id, title: title.isEmpty ? "Group" : title,
                             members: addresses.filter { $0 != identity.address }, now: now())
            return true
        case .channel, .assistant:
            return false
        }
    }

    /// Adds group members we haven't met as Unverified contacts, so we can read and write to them.
    /// Contacts we already have keep their own key: a group can never change a contact's key.
    private func introduce(_ members: [GroupMember], known: Set<TransportAddress>) {
        for member in members where member.address != identity.address && !known.contains(member.address) {
            do {
                let key = try SealedCrypto.importPublicKey(member.publicKey)
                let name = String(member.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ContactCode.maxNameBytes))
                try contacts.offer(OfferedKey(displayName: name.isEmpty ? "Group member" : name, address: member.address,
                                              fingerprint: key.fingerprint.hex, publicKey: key.data, source: .receivedOtherwise),
                                   from: identity, now: now())
            } catch {
                Self.log.error("Skipped group member \(member.address.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

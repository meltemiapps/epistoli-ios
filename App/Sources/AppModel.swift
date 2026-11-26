import Foundation
import Observation
import EpistoliCore
import KeyExchange
import Messaging
import Security
import SealedStorage

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case failed(String)
        case onboarding
        case ready
    }

    private(set) var phase: Phase
    private(set) var identity: Identity?
    private(set) var contacts: [Contact] = []
    private(set) var conversations: [Conversation] = []
    /// Bumped whenever messages change, so open chats reload.
    private(set) var revision = 0
    /// The last send that failed, shown in the chat.
    var sendError: String?
    private let env: AppEnvironment?
    private var messenger: Messenger?
    private var receiving: Task<Void, Never>?

    init(environment: () throws -> AppEnvironment = AppEnvironment.live) {
        var env: AppEnvironment?
        var identity: Identity?
        var contacts: [Contact] = []
        var phase = Phase.onboarding
        do {
            let opened = try environment()
            identity = try opened.identities.load()
            contacts = try opened.contacts.all()
            env = opened
            phase = identity == nil ? .onboarding : .ready
        } catch {
            phase = .failed(String(describing: error))
        }
        self.env = env
        self.identity = identity
        self.contacts = contacts
        self.phase = phase
        makeMessenger()
    }

    private func makeMessenger() {
        guard let env, let identity else { messenger = nil; return }
        messenger = Messenger(identity: identity, contacts: env.contacts, store: env.conversations, transport: env.transport)
        reloadConversations()
    }

    // MARK: Identity

    func createIdentity(name: String) throws {
        guard let env else { return }
        identity = try env.identities.create(displayName: name)
        phase = .ready
        makeMessenger()
        startReceiving()
    }

    /// Where the key that wraps the database key and the identity key actually lives, read back
    /// from the Keychain. Shown in Settings; on a device it must say Secure Enclave (Checkpoint E).
    var keyProtection: String {
        guard let env else { return "Unavailable" }
        do {
            let token = try SecureEnclaveKeyWrapper.storedKeyTokenID(tag: env.wrapperTag)
            return token == (kSecAttrTokenIDSecureEnclave as String) ? "Secure Enclave" : "Software key (simulator only)"
        } catch {
            return "Unknown (\(error))"
        }
    }

    func myCode() throws -> String {
        guard let identity else { throw IdentityError.emptyName }
        return try ContactCodec.code(for: identity)
    }

    #if DEBUG
    /// Debug builds only: a new key for the same name and address, as a new phone would have.
    func simulateNewPhone() throws {
        guard let env, let identity else { return }
        self.identity = try env.identities.replaceKey(of: identity)
        makeMessenger()
    }
    #endif

    // MARK: Contacts

    /// What accepting `offer` would do, without saving anything.
    func preview(_ offer: OfferedKey) -> Result<(contact: Contact, outcome: KeyOfferOutcome), KeyOfferError> {
        guard let identity else { return .failure(.ownCode) }
        let existing = contacts.first { $0.address == offer.address }
        let sameKey = contacts.first { $0.currentKey.fingerprint == offer.fingerprint }
        return Result { () throws(KeyOfferError) in
            try ContactRules.apply(offer, to: existing, contactWithSameKey: sameKey,
                                   ownFingerprint: identity.fingerprint.hex, ownAddress: identity.address, now: Date())
        }
    }

    /// Saves `offer`. A new contact gets `name` (the scanner may change the suggested one).
    @discardableResult
    func accept(_ offer: OfferedKey, name: String? = nil) throws -> Contact {
        guard let env, let identity else { throw KeyOfferError.ownCode }
        let result = try env.contacts.offer(offer, from: identity)
        if result.outcome == .added, let name, name != result.contact.displayName {
            try env.contacts.rename(result.contact.id, to: name)
        }
        try reloadContacts()
        // A new or changed key may make set-aside messages readable.
        try? messenger?.retryRejected()
        return contacts.first { $0.id == result.contact.id } ?? result.contact
    }

    func rename(_ contact: Contact, to name: String) throws {
        try env?.contacts.rename(contact.id, to: name)
        try reloadContacts()
    }

    /// Removes the contact and the one-to-one chat with them. Groups they're in stay.
    func delete(_ contact: Contact) throws {
        guard let env, let identity else { return }
        if let chat = ConversationID.direct(identity.address, contact.address) { try env.conversations.delete(chat) }
        try env.contacts.delete(contact.id)
        try reloadContacts()
        reloadConversations()
    }

    func contact(id: UUID) -> Contact? { contacts.first { $0.id == id } }

    func contact(address: TransportAddress) -> Contact? { contacts.first { $0.address == address } }

    private func reloadContacts() throws {
        guard let env else { return }
        contacts = try env.contacts.all()
    }

    // MARK: Chats

    /// Polls our mailbox every second while the app runs. Section 5 replaces this with CloudKit
    /// fetches on launch, on push hints, in the background and on pull-to-refresh.
    func startReceiving() {
        guard receiving == nil else { return }
        receiving = Task { [weak self] in
            while !Task.isCancelled {
                await self?.receiveNow()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func receiveNow() async {
        guard let messenger else { return }
        let report = await Task.detached { try? messenger.receive() }.value
        if let report, report.received > 0 {
            try? reloadContacts()   // a group can introduce new members
            reloadConversations()
        }
    }

    private func reloadConversations() {
        conversations = (try? env?.conversations.conversations()) ?? []
        revision += 1
    }

    /// The list on the first screen: every chat, then contacts we haven't written to yet.
    var chatRows: [ChatRow] {
        guard let identity else { return [] }
        let chats = conversations.map(ChatRow.conversation)
        let started = Set(conversations.map(\.id))
        let others = contacts.filter { contact in
            ConversationID.direct(identity.address, contact.address).map { !started.contains($0) } ?? false
        }
        return chats + others.map(ChatRow.contact)
    }

    func conversation(_ id: ConversationID) -> Conversation? { conversations.first { $0.id == id } }

    func messages(in id: ConversationID) -> [ChatMessage] {
        _ = revision
        return (try? env?.conversations.messages(in: id)) ?? []
    }

    func attachmentData(_ info: AttachmentInfo) -> Data? {
        try? env?.conversations.attachmentData(info.blob)
    }

    /// The chat's name: the contact's name for a direct chat, the title for a group.
    func title(of conversation: Conversation) -> String {
        if conversation.kind == .group { return conversation.title ?? "Group" }
        return conversation.members.first.flatMap(contact(address:))?.displayName ?? "Former contact"
    }

    func name(of address: TransportAddress) -> String {
        if address == identity?.address { return "You" }
        return contact(address: address)?.displayName ?? "Someone"
    }

    /// Members whose key changed and hasn't been scanned in person: the chat shows a banner for
    /// each and warns before sending.
    func keyChangedMembers(of conversation: Conversation) -> [Contact] {
        conversation.members.compactMap(contact(address:)).filter(\.needsKeyChangeWarning)
    }

    func openChat(with contact: Contact) throws -> ConversationID {
        guard let messenger else { throw MessagingError.noRecipients }
        let chat = try messenger.directConversation(with: contact)
        reloadConversations()
        return chat.id
    }

    func createGroup(title: String, members: [Contact]) throws -> ConversationID {
        guard let messenger else { throw MessagingError.noRecipients }
        let group = try messenger.createGroup(title: title, members: members)
        reloadConversations()
        return group.id
    }

    func send(text: String, in id: ConversationID) async {
        await perform { try $0.send(text: text, in: id) }
    }

    func send(attachment: OutgoingAttachment, in id: ConversationID) async {
        await perform { try $0.send(attachment: attachment, in: id) }
    }

    func setPGP(_ on: Bool, in id: ConversationID) async {
        await perform { try $0.setPGP(on, in: id) }
    }

    /// Encrypting can take a moment for a large attachment, so it runs off the main thread.
    private func perform(_ action: @escaping @Sendable (Messenger) throws -> ChatMessage) async {
        guard let messenger else { return }
        let result = await Task.detached { Result { try action(messenger) } }.value
        if case .failure(let error) = result { sendError = Self.describe(error) } else { sendError = nil }
        reloadConversations()
    }

    static func describe(_ error: any Error) -> String {
        switch error as? MessagingError {
        case .attachmentTooLarge: "That file is too large. Attachments can be up to \(AttachmentLimits.maxBytes / 1_048_576) MB."
        case .noRecipients: "No one in this chat can receive messages: they're no longer your contacts."
        case .groupTooLarge: "Groups can have up to \(ConversationLimits.maxGroupMembers) people, including you."
        case .emptyMessage, .unknownConversation, nil: "Couldn't send: \(error.localizedDescription)"
        }
    }
}

/// A row on the chats list.
enum ChatRow: Identifiable {
    case conversation(Conversation)
    /// A contact with no chat yet.
    case contact(Contact)

    var id: String {
        switch self {
        case .conversation(let c): c.id.rawValue
        case .contact(let c): c.id.uuidString
        }
    }
}

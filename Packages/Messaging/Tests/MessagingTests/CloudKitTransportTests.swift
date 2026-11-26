import Foundation
import GRDB
import Testing
import EpistoliCore
import KeyExchange
import SealedCrypto
import SealedStorage
@testable import Messaging

/// One phone on the mocked iCloud: its own iCloud user, identity, database and transport state.
private final class CloudPhone {
    let user: String
    let identity: Identity
    let contacts: ContactStore
    let store: ConversationStore
    let folder: URL
    let cloud: MockCloud
    var transport: CloudKitTransport
    var messenger: Messenger

    init(_ name: String, user: String, cloud: MockCloud) throws {
        self.user = user
        self.cloud = cloud
        let identities = IdentityStore(store: MemorySecretStore(), wrapper: try SecureEnclaveKeyWrapper.ephemeral())
        identity = try identities.create(displayName: name, address: CloudKitTransport.address(forUser: user)!)
        var migrator = DatabaseMigrator()
        ContactStore.registerMigrations(in: &migrator)
        ConversationStore.registerMigrations(in: &migrator)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ck-\(UUID().uuidString).sqlite")
        let db = try SealedDatabase.open(at: url, key: try DatabaseKeyProvider(store: MemorySecretStore(), wrapper: SecureEnclaveKeyWrapper.ephemeral()).key(),
                                         migrator: migrator)
        contacts = ContactStore(db: db)
        store = ConversationStore(db: db)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ck-state-\(UUID().uuidString)", isDirectory: true)
        transport = try CloudKitTransport(database: MockCloudDatabase(cloud: cloud, user: user), me: identity.address, folder: folder)
        messenger = Messenger(identity: identity, contacts: contacts, store: store, transport: transport)
    }

    /// The app relaunched: a new transport reading the same local state.
    func relaunch() throws {
        transport = try CloudKitTransport(database: MockCloudDatabase(cloud: cloud, user: user), me: identity.address, folder: folder)
        messenger = Messenger(identity: identity, contacts: contacts, store: store, transport: transport)
    }

    @discardableResult
    func add(_ other: CloudPhone, scanned: Bool = true) throws -> Contact {
        let offer = try ContactCodec.read(try ContactCodec.code(for: other.identity), source: scanned ? .scannedInPerson : .receivedOtherwise)
        return try contacts.offer(offer, from: identity).contact
    }

    func contact(_ other: CloudPhone) throws -> Contact {
        try #require(try contacts.all().first { $0.address == other.identity.address })
    }

    func chat(with other: CloudPhone) throws -> ConversationID {
        try messenger.directConversation(with: contact(other)).id
    }

    func texts(in id: ConversationID) throws -> [String] {
        try store.messages(in: id).compactMap { if case .text(let t) = $0.content { t } else { nil } }
    }
}

private func family(_ names: [(String, String)]) throws -> (MockCloud, [CloudPhone]) {
    let cloud = MockCloud()
    let phones = try names.map { try CloudPhone($0.0, user: $0.1, cloud: cloud) }
    return (cloud, phones)
}

private func pair() throws -> (MockCloud, CloudPhone, CloudPhone) {
    let (cloud, phones) = try family([("Μαρία", "_aaaa1111"), ("Νίκος", "_bbbb2222")])
    try phones[0].add(phones[1]); try phones[1].add(phones[0])
    return (cloud, phones[0], phones[1])
}

private func contains(_ haystack: Data, _ needle: String) -> Bool { haystack.range(of: Data(needle.utf8)) != nil }

@Suite struct CloudKitTransportTests {
    @Test func addressesAndNames() {
        let address = CloudKitTransport.address(forUser: "_0123abcd")
        #expect(address?.rawValue == "icloud:_0123abcd")
        #expect(CloudKitTransport.address(forUser: "../x") == nil)
        let chat = ConversationID.direct(address!, CloudKitTransport.address(forUser: "_ffff")!)!
        let zone = CloudKitTransport.zoneName(for: chat)
        #expect(zone.hasPrefix("c-") && zone.count == 34 && !zone.contains("0123abcd"))
        #expect(CloudKitTransport.inviteKey(for: address!).count == 64)
        #expect(!CloudKitTransport.inviteKey(for: address!).contains("0123abcd"))
    }

    @Test func firstMessageSharesTheChatAndArrives() async throws {
        let (cloud, maria, nikos) = try pair()
        let chat = try maria.chat(with: nikos)
        try await maria.messenger.send(text: "Καλησπέρα!", in: chat)

        // One zone, owned by Maria, shared with Nikos only; one invitation in the public database.
        let zones = await cloud.zones
        #expect(zones[maria.user]?.count == 1)
        #expect(zones[maria.user]?.values.first?.participants == [nikos.user])
        #expect(await cloud.publicRecords.count == 1)

        let report = try await nikos.messenger.receive()
        #expect(report.joined == 1 && report.received == 1)
        #expect(try nikos.texts(in: chat) == ["Καλησπέρα!"])
    }

    @Test func repliesGoToTheSameZoneAndBothSidesSeeOneChat() async throws {
        let (cloud, maria, nikos) = try pair()
        let chat = try maria.chat(with: nikos)
        try await maria.messenger.send(text: "Hi", in: chat)
        try await nikos.messenger.receive()
        try await nikos.messenger.send(text: "Hello back", in: chat)
        // Nikos wrote into Maria's zone: still one zone, no second share or invitation.
        #expect(await cloud.zones[nikos.user] == nil)
        #expect(await cloud.publicRecords.count == 1)
        #expect(try await maria.messenger.receive().received == 1)
        #expect(try maria.texts(in: chat) == ["Hi", "Hello back"])
        // Our own records in the zone are never handed to us as incoming.
        #expect(try await maria.messenger.receive() == ReceiveReport())
        #expect(try await nikos.messenger.receive() == ReceiveReport())
    }

    @Test func attachmentsBothWays() async throws {
        let (_, maria, nikos) = try pair()
        let chat = try maria.chat(with: nikos)
        let photo = Data((0..<200_000).map { UInt8($0 % 253) })
        try await maria.messenger.send(attachment: OutgoingAttachment(data: photo, name: "beach.jpg", mime: "image/jpeg", source: .photos), in: chat)
        #expect(try await nikos.messenger.receive().received == 1)
        let pdf = Data("%PDF recipe".utf8)
        try await nikos.messenger.send(attachment: OutgoingAttachment(data: pdf, name: "recipe.pdf", mime: "application/pdf", source: .files), in: chat)
        #expect(try await maria.messenger.receive().received == 1)

        guard case .attachment(let a) = try nikos.store.messages(in: chat)[0].content,
              case .attachment(let b) = try maria.store.messages(in: chat)[1].content else { Issue.record("no attachments"); return }
        #expect(try nikos.store.attachmentData(a.blob) == photo)
        #expect(try maria.store.attachmentData(b.blob) == pdf)
    }

    @Test func appleSeesOnlyCiphertextWithPGPOn() async throws {
        let (cloud, maria, nikos) = try pair()
        let chat = try maria.chat(with: nikos)
        try await maria.messenger.send(text: "the spare key is under the blue pot", in: chat)
        try await maria.messenger.send(attachment: OutgoingAttachment(data: Data("JPEG-BYTES".utf8), name: "beach.jpg", mime: "image/jpeg", source: .photos), in: chat)
        let stored = await cloud.allStoredData()
        // Envelopes are JSON with a Base64 body: check the decoded bodies too.
        let bodies = stored.compactMap { try? Envelope.decode($0).body }
        for data in stored + bodies {
            for secret in ["the spare key", "beach.jpg", "JPEG-BYTES", "Μαρία", "Νίκος", "icloud.com/share", chat.rawValue] {
                #expect(!contains(data, secret), "\(secret) is readable in iCloud")
            }
        }
        // The invitation is filed under a hash, not Nikos's address.
        let invite = try #require(await cloud.publicRecords.first)
        #expect(invite.strings == ["recipient": CloudKitTransport.inviteKey(for: nikos.identity.address)])
    }

    @Test func groupSharedWithEveryMember() async throws {
        let (cloud, phones) = try family([("Maria", "_m1"), ("Nikos", "_n2"), ("Eleni", "_e3")])
        let (maria, nikos, eleni) = (phones[0], phones[1], phones[2])
        try maria.add(nikos); try maria.add(eleni); try nikos.add(maria); try eleni.add(maria)
        let group = try maria.messenger.createGroup(title: "Family", members: [try maria.contact(nikos), try maria.contact(eleni)]).id
        try await maria.messenger.send(text: "Dinner at 8", in: group)
        #expect(await cloud.zones[maria.user]?.values.first?.participants == [nikos.user, eleni.user])
        #expect(try await nikos.messenger.receive().received == 1)
        #expect(try await eleni.messenger.receive().received == 1)
        // Nikos and Eleni never met: the group introduced them, and Nikos writes in Maria's zone.
        try await nikos.messenger.send(text: "I'll bring bread", in: group)
        try await eleni.messenger.receive()
        #expect(try eleni.texts(in: group) == ["Dinner at 8", "I'll bring bread"])
    }

    @Test func invitationsFromStrangersWaitAndForgedOnesAreRefused() async throws {
        let (cloud, phones) = try family([("Maria", "_m1"), ("Nikos", "_n2"), ("Eleni", "_e3")])
        let (maria, nikos, eleni) = (phones[0], phones[1], phones[2])
        try maria.add(nikos)                      // Nikos hasn't added Maria yet
        let chat = try maria.chat(with: nikos)
        try await maria.messenger.send(text: "Hi", in: chat)
        var report = try await nikos.messenger.receive()
        #expect(report.waiting == 1 && report.joined == 0)

        // Eleni (a contact of Nikos) forges an invitation to a chat between Maria and Nikos,
        // pointing at a share she controls. A direct chat must be between the sender and us.
        try nikos.add(eleni); try eleni.add(nikos)
        let forged = Invitation(from: eleni.identity.address, conversation: chat, link: "https://www.icloud.com/share/evil")
        let body = try SealedCrypto.encrypt(forged.encoded(), to: [try PGPPublicKey(data: try eleni.contact(nikos).currentKey.publicKey)],
                                            signedBy: eleni.identity.privateKey)
        await cloud.savePublic(CloudRecord(type: "Invite", name: UUID().uuidString.lowercased(),
                                           strings: ["recipient": CloudKitTransport.inviteKey(for: nikos.identity.address)],
                                           bytes: ["envelope": try Envelope(id: UUID(), from: eleni.identity.address, mode: .pgp, body: body).encoded()]))
        report = try await nikos.messenger.receive()
        #expect(report.rejected == 1 && report.joined == 0)

        // Once Nikos adds Maria, her invitation is accepted and the message arrives.
        try nikos.add(maria)
        report = try await nikos.messenger.receive()
        #expect(report.joined == 1 && report.received == 1)
        #expect(try nikos.texts(in: chat) == ["Hi"])
    }

    @Test func outsidersCannotJoinEvenWithTheLink() async throws {
        let (cloud, maria, nikos) = try pair()
        let eleni = try CloudPhone("Eleni", user: "_e3", cloud: cloud)
        let chat = try maria.chat(with: nikos)
        try await maria.messenger.send(text: "Private", in: chat)
        let url = try #require(await cloud.zones[maria.user]?.values.first?.url)
        // The share has no public access: someone who isn't a participant can't accept it.
        await #expect(throws: MockCloud.Failure.notPermitted) {
            try await eleni.transport.join(Invitation(from: maria.identity.address, conversation: chat, link: url.absoluteString))
        }
        // Links that aren't iCloud share links are refused before CloudKit sees them.
        await #expect(throws: TransportError.invalidLink) {
            try await nikos.transport.join(Invitation(from: maria.identity.address, conversation: chat, link: "http://example.com/x"))
        }
    }

    @Test func relaunchDoesNotRedeliverOrLoseMessages() async throws {
        let (_, maria, nikos) = try pair()
        let chat = try maria.chat(with: nikos)
        try await maria.messenger.send(text: "One", in: chat)
        try await nikos.messenger.receive()
        try nikos.relaunch()
        try await maria.messenger.send(text: "Two", in: chat)
        let report = try await nikos.messenger.receive()
        #expect(report.received == 1 && report.joined == 0)
        #expect(try nikos.texts(in: chat) == ["One", "Two"])
    }

    @Test func alertsSayOnlyNewMessage() async throws {
        let (cloud, maria, _) = try pair()
        try await maria.transport.subscribeToAlerts()
        #expect(await cloud.subscriptions[maria.user] == "New message")
    }
}

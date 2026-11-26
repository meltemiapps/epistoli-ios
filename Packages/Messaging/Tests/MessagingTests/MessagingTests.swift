import Foundation
import GRDB
import Testing
import EpistoliCore
import KeyExchange
import KeyExchangeTestSupport
import SealedCrypto
import SealedStorage
@testable import Messaging

/// One phone: identity, database and messenger, on a loopback folder shared with the others.
private final class Phone {
    let identity: Identity
    let identities: IdentityStore
    let contacts: ContactStore
    let store: ConversationStore
    let transport: LoopbackTransport
    var messenger: Messenger

    init(_ name: String, root: URL) throws {
        identities = IdentityStore(store: MemorySecretStore(), wrapper: try SecureEnclaveKeyWrapper.ephemeral())
        identity = try identities.create(displayName: name)
        var migrator = DatabaseMigrator()
        ContactStore.registerMigrations(in: &migrator)
        ConversationStore.registerMigrations(in: &migrator)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("msg-\(UUID().uuidString).sqlite")
        let key = try DatabaseKeyProvider(store: MemorySecretStore(), wrapper: SecureEnclaveKeyWrapper.ephemeral()).key()
        let db = try SealedDatabase.open(at: url, key: key, migrator: migrator)
        contacts = ContactStore(db: db)
        store = ConversationStore(db: db)
        transport = LoopbackTransport(root: root)
        messenger = Messenger(identity: identity, contacts: contacts, store: store, transport: transport)
    }

    /// Adds `other` as a contact from their code (pasted unless `scanned`).
    @discardableResult
    func add(_ other: Phone, scanned: Bool = false) throws -> Contact {
        let offer = try ContactCodec.read(try ContactCodec.code(for: other.identity),
                                          source: scanned ? .scannedInPerson : .receivedOtherwise)
        return try contacts.offer(offer, from: identity).contact
    }

    func contact(_ other: Phone) throws -> Contact {
        try #require(try contacts.all().first { $0.address == other.identity.address })
    }

    func chat(with other: Phone) throws -> Conversation {
        try messenger.directConversation(with: contact(other))
    }

    func texts(in id: ConversationID) throws -> [String] {
        try store.messages(in: id).compactMap { if case .text(let t) = $0.content { t } else { nil } }
    }
}

private func sharedFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("loopback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func pair() throws -> (Phone, Phone, URL) {
    let root = try sharedFolder()
    let maria = try Phone("Μαρία", root: root), nikos = try Phone("Νίκος", root: root)
    try maria.add(nikos, scanned: true)
    try nikos.add(maria, scanned: true)
    return (maria, nikos, root)
}

/// Every file the transport holds, for checking what a cloud provider would see.
private func transportFiles(_ root: URL) throws -> [Data] {
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
    return try walker.compactMap { item in
        let url = item as! URL
        return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? try Data(contentsOf: url) : nil
    }
}

private func contains(_ haystack: Data, _ needle: String) -> Bool {
    haystack.range(of: Data(needle.utf8)) != nil
}

@Suite struct DirectChatTests {
    @Test func textBothWays() throws {
        let (maria, nikos, _) = try pair()
        let chat = try maria.chat(with: nikos)
        try maria.messenger.send(text: "Καλησπέρα! Did the beach photos arrive?", in: chat.id)
        #expect(try nikos.messenger.receive().received == 1)
        // Both phones derive the same chat.
        #expect(try nikos.chat(with: maria).id == chat.id)
        try nikos.messenger.send(text: "Yes, all of them.", in: chat.id)
        #expect(try maria.messenger.receive().received == 1)

        let expected = ["Καλησπέρα! Did the beach photos arrive?", "Yes, all of them."]
        #expect(try maria.texts(in: chat.id) == expected)
        #expect(try nikos.texts(in: chat.id) == expected)
        #expect(try maria.store.messages(in: chat.id).map(\.outgoing) == [true, false])
        #expect(try maria.store.messages(in: chat.id).map(\.lamport) == [1, 2])
        #expect(try maria.store.messages(in: chat.id).allSatisfy(\.pgp))
        // Mailboxes are empty afterwards.
        #expect(try maria.transport.inbox(for: maria.identity.address).isEmpty)
        #expect(try nikos.transport.inbox(for: nikos.identity.address).isEmpty)
    }

    @Test func pgpOnTheTransportSeesOnlyCiphertext() throws {
        let (maria, nikos, root) = try pair()
        let chat = try maria.chat(with: nikos)
        let secret = "the spare key is under the blue pot"
        try maria.messenger.send(text: secret, in: chat.id)
        let photo = Data("JPEG-BYTES beach sunset photo".utf8)
        try maria.messenger.send(attachment: OutgoingAttachment(data: photo, name: "beach.jpg", mime: "image/jpeg", source: .photos), in: chat.id)
        let files = try transportFiles(root)
        #expect(files.count == 3)
        let bodies = files.map { (try? Envelope.decode($0).body) ?? $0 }
        for file in files + bodies {
            #expect(!contains(file, secret) && !contains(file, "beach.jpg") && !contains(file, "JPEG-BYTES"))
            #expect(!contains(file, maria.identity.displayName) && !contains(file, nikos.identity.displayName))
            #expect(scannerFinds(maria.identity, in: file) == false)
        }
    }

    @Test func attachmentBothWays() throws {
        let (maria, nikos, _) = try pair()
        let chat = try maria.chat(with: nikos)
        let photo = Data((0..<300_000).map { UInt8($0 % 251) })
        let sent = try maria.messenger.send(attachment: OutgoingAttachment(data: photo, name: "beach.jpg", mime: "image/jpeg", source: .photos), in: chat.id)
        #expect(try nikos.messenger.receive().received == 1)
        let pdf = Data("%PDF-1.7 recipe".utf8)
        try nikos.messenger.send(attachment: OutgoingAttachment(data: pdf, name: "recipe.pdf", mime: "application/pdf", source: .iCloudDrive), in: chat.id)
        #expect(try maria.messenger.receive().received == 1)

        let atNikos = try nikos.store.messages(in: chat.id)
        guard case .attachment(let info) = atNikos[0].content else { Issue.record("not an attachment"); return }
        #expect(info.name == "beach.jpg" && info.size == photo.count && info.source == .photos)
        #expect(try nikos.store.attachmentData(info.blob) == photo)
        #expect(atNikos[0].id == sent.id)
        guard case .attachment(let back) = try maria.store.messages(in: chat.id)[1].content else { Issue.record("not an attachment"); return }
        #expect(back.source == .iCloudDrive && back.detail.hasSuffix("from iCloud Drive"))
        #expect(try maria.store.attachmentData(back.blob) == pdf)
    }

    @Test func pgpOffIsSignedButReadable() throws {
        let (maria, nikos, root) = try pair()
        let chat = try maria.chat(with: nikos)
        try maria.messenger.setPGP(false, in: chat.id)
        #expect(try maria.store.conversation(chat.id)?.pgp == false)
        try maria.messenger.send(text: "PGP is off now", in: chat.id)

        // The setting notice is encrypted; the message after it is readable on the transport.
        let bodies = try transportFiles(root).compactMap { try? Envelope.decode($0).body }
        #expect(bodies.count == 2)
        #expect(bodies.filter { contains($0, "PGP is off now") }.count == 1)
        #expect(bodies.allSatisfy { !contains($0, "pgpSetting") })

        #expect(try nikos.messenger.receive().received == 2)
        // The setting is shared: Nikos's side of the chat is now PGP off too.
        #expect(try nikos.store.conversation(chat.id)?.pgp == false)
        let received = try nikos.store.messages(in: chat.id)
        #expect(received.map(\.pgp) == [true, false])
        #expect(received[0].content == .pgpSetting(on: false))

        try nikos.messenger.setPGP(true, in: chat.id)
        try maria.messenger.receive()
        #expect(try maria.store.conversation(chat.id)?.pgp == true)
    }

    @Test func tamperedEnvelopesAreRejected() throws {
        let (maria, nikos, root) = try pair()
        let chat = try maria.chat(with: nikos)
        try maria.messenger.setPGP(false, in: chat.id)
        try nikos.messenger.receive()
        try maria.messenger.send(text: "Pay 10 euros", in: chat.id)

        let layout = LoopbackLayout(root: root)
        let box = try #require(layout.mailbox(for: nikos.identity.address))
        let file = try #require(try FileManager.default.contentsOfDirectory(at: box, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        var envelope = try Envelope.decode(Data(contentsOf: file))
        envelope.body = Data(String(decoding: envelope.body, as: UTF8.self).replacingOccurrences(of: "10", with: "90").utf8)
        try envelope.encoded().write(to: file)

        let report = try nikos.messenger.receive()
        #expect(report.received == 0 && report.rejected == 1)
        #expect(try !nikos.texts(in: chat.id).contains { $0.contains("90") })
    }

    @Test func strangersWaitUntilAdded() throws {
        let root = try sharedFolder()
        let maria = try Phone("Maria", root: root), nikos = try Phone("Nikos", root: root)
        try maria.add(nikos)
        try maria.messenger.send(text: "Hello", in: try maria.chat(with: nikos).id)
        // Nikos hasn't added Maria: nothing is shown, and the envelope waits.
        #expect(try nikos.messenger.receive() == { var r = ReceiveReport(); r.waiting = 1; return r }())
        #expect(try nikos.store.conversations().isEmpty)
        try nikos.add(maria)
        #expect(try nikos.messenger.receive().received == 1)
        #expect(try nikos.store.conversations().count == 1)
    }

    @Test func duplicatesAreIgnored() throws {
        let (maria, nikos, _) = try pair()
        let chat = try maria.chat(with: nikos)
        let message = try maria.messenger.send(text: "Once", in: chat.id)
        let box = try #require(nikos.transport.layout.envelopeFile(message.id, for: nikos.identity.address))
        let copy = try Data(contentsOf: box)
        try nikos.messenger.receive()
        try nikos.transport.deliver(copy, id: message.id, to: nikos.identity.address)
        #expect(try nikos.messenger.receive().received == 0)
        #expect(try nikos.texts(in: chat.id) == ["Once"])
        #expect(try nikos.transport.inbox(for: nikos.identity.address).isEmpty)
    }

    @Test func messagesFromAnOldKeyAreRejectedUntilTheNewKeyIsAccepted() throws {
        let (maria, nikos, _) = try pair()
        // Maria gets a new phone: same address, new key.
        let newMaria = try maria.identities.replaceKey(of: maria.identity)
        maria.messenger = Messenger(identity: newMaria, contacts: maria.contacts, store: maria.store, transport: maria.transport)
        let chat = try maria.chat(with: nikos)
        try maria.messenger.send(text: "New phone!", in: chat.id)
        // Signed by a key Nikos doesn't have: set aside, not shown.
        #expect(try nikos.messenger.receive().rejected == 1)
        #expect(try nikos.store.conversations().isEmpty)

        // Nikos accepts the new key from a pasted code: Unverified with a key-change warning.
        let offer = try ContactCodec.read(ContactCodec.code(for: newMaria), source: .receivedOtherwise)
        let result = try nikos.contacts.offer(offer, from: nikos.identity)
        #expect(result.outcome == .keyChanged(warning: true) && result.contact.verification == .unverified)
        try nikos.messenger.retryRejected()
        #expect(try nikos.messenger.receive().received == 1)
        #expect(try nikos.texts(in: chat.id) == ["New phone!"])
    }

    @Test func lamportOrderingIsTheSameOnBothPhones() throws {
        let (maria, nikos, _) = try pair()
        let chat = try maria.chat(with: nikos)
        _ = try nikos.chat(with: maria)
        // Both write before seeing each other's messages: equal counters.
        try maria.messenger.send(text: "M1", in: chat.id)
        try nikos.messenger.send(text: "N1", in: chat.id)
        try maria.messenger.receive()
        try nikos.messenger.receive()
        try maria.messenger.send(text: "M2", in: chat.id)
        try nikos.messenger.receive()
        #expect(try maria.texts(in: chat.id) == nikos.texts(in: chat.id))
        #expect(try maria.texts(in: chat.id).last == "M2")
        #expect(try nikos.store.messages(in: chat.id).map(\.lamport) == [1, 1, 2])
    }

    @Test func attachmentLimit() throws {
        let (maria, nikos, _) = try pair()
        let chat = try maria.chat(with: nikos)
        let big = OutgoingAttachment(data: Data(count: AttachmentLimits.maxBytes + 1), name: "big.mov", mime: "video/quicktime", source: .files)
        #expect(throws: MessagingError.attachmentTooLarge) { try maria.messenger.send(attachment: big, in: chat.id) }
    }
}

@Suite struct GroupChatTests {
    @Test func groupFansOutAndIntroducesMembers() throws {
        let root = try sharedFolder()
        let maria = try Phone("Μαρία", root: root), nikos = try Phone("Νίκος", root: root), eleni = try Phone("Ελένη", root: root)
        // Maria knows both; Nikos and Eleni know only Maria.
        try maria.add(nikos, scanned: true); try maria.add(eleni, scanned: true)
        try nikos.add(maria, scanned: true); try eleni.add(maria, scanned: true)

        let group = try maria.messenger.createGroup(title: "Οικογένεια", members: [try maria.contact(nikos), try maria.contact(eleni)])
        try maria.messenger.send(text: "Dinner at 8", in: group.id)
        #expect(try nikos.messenger.receive().received == 1)
        #expect(try eleni.messenger.receive().received == 1)
        #expect(try nikos.store.conversation(group.id)?.title == "Οικογένεια")

        // Eleni became an Unverified contact on Nikos's phone, so he can write to the whole group.
        let introduced = try nikos.contact(eleni)
        #expect(introduced.verification == .unverified && introduced.displayName == "Ελένη")
        #expect(try nikos.contact(maria).verification == .verified)
        try nikos.messenger.send(text: "I'll bring bread", in: group.id)
        try maria.messenger.receive(); try eleni.messenger.receive()
        #expect(try eleni.texts(in: group.id) == ["Dinner at 8", "I'll bring bread"])
        #expect(try maria.texts(in: group.id) == ["Dinner at 8", "I'll bring bread"])
    }

    @Test func aGroupCannotChangeAContactsKey() throws {
        let root = try sharedFolder()
        let maria = try Phone("Maria", root: root), nikos = try Phone("Nikos", root: root), eleni = try Phone("Eleni", root: root)
        try maria.add(nikos); try maria.add(eleni); try nikos.add(maria); try nikos.add(eleni, scanned: true)
        let before = try nikos.contact(eleni)
        // Maria's phone holds a different key for Eleni (say, an old one): Nikos keeps his.
        let fakeEleni = try eleni.identities.replaceKey(of: eleni.identity)
        try maria.contacts.offer(ContactCodec.read(ContactCodec.code(for: fakeEleni), source: .receivedOtherwise), from: maria.identity)
        let group = try maria.messenger.createGroup(title: "Family", members: [try maria.contact(nikos), try maria.contact(eleni)])
        try maria.messenger.send(text: "Hi", in: group.id)
        try nikos.messenger.receive()
        #expect(try nikos.contact(eleni) == before)
    }

    @Test func onlyMembersCanWriteToAGroup() throws {
        let root = try sharedFolder()
        let maria = try Phone("Maria", root: root), nikos = try Phone("Nikos", root: root), eleni = try Phone("Eleni", root: root)
        try maria.add(nikos); try maria.add(eleni); try nikos.add(maria); try eleni.add(maria); try nikos.add(eleni); try eleni.add(nikos)
        let group = try maria.messenger.createGroup(title: "Maria and Nikos", members: [try maria.contact(nikos)])
        try maria.messenger.send(text: "Just us", in: group.id)
        try nikos.messenger.receive()
        // Eleni isn't a member. A message she makes up for that group is refused.
        let forged = Payload(id: UUID(), from: eleni.identity.address, conversation: group.id, group: nil,
                             lamport: 5, sentAt: Date(), content: .text("I'm in"))
        let body = try SealedCrypto.encrypt(try forged.encoded(), to: [try PGPPublicKey(data: try eleni.contact(nikos).currentKey.publicKey)],
                                            signedBy: eleni.identity.privateKey)
        try nikos.transport.deliver(try Envelope(id: forged.id, from: eleni.identity.address, mode: .pgp, body: body).encoded(),
                                    id: forged.id, to: nikos.identity.address)
        #expect(try nikos.messenger.receive().rejected == 1)
        #expect(try nikos.texts(in: group.id) == ["Just us"])
    }

    @Test func groupSizeLimit() throws {
        let root = try sharedFolder()
        let maria = try Phone("Maria", root: root)
        #expect(throws: MessagingError.noRecipients) { try maria.messenger.createGroup(title: "Alone", members: []) }
    }
}

private func scannerFinds(_ identity: Identity, in data: Data) -> Bool {
    !PrivateKeyLeakScanner(privateKey: identity.privateKey, publicKey: identity.publicKey).encodingsFound(in: data).isEmpty
}

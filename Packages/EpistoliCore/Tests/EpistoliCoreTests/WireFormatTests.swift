import Foundation
import Testing
@testable import EpistoliCore

private let maria = TransportAddress(rawValue: "loopback:" + String(repeating: "a", count: 32))!
private let nikos = TransportAddress(rawValue: "loopback:" + String(repeating: "b", count: 32))!

@Suite struct ConversationIDTests {
    @Test func directIDIsTheSameOnBothPhones() throws {
        let a = try #require(ConversationID.direct(maria, nikos))
        let b = try #require(ConversationID.direct(nikos, maria))
        #expect(a == b && a.kind == .direct)
        #expect(Set(a.directMembers) == [maria, nikos])
        #expect(ConversationID(rawValue: a.rawValue) == a)
    }

    @Test func directIDNeedsTwoDifferentPeople() {
        #expect(ConversationID.direct(maria, maria) == nil)
        // Unsorted, a single address, or junk: not a valid ID.
        #expect(ConversationID(rawValue: "d:\(nikos.rawValue) \(maria.rawValue)") == nil)
        #expect(ConversationID(rawValue: "d:\(maria.rawValue)") == nil)
        #expect(ConversationID(rawValue: "x:1") == nil)
    }

    @Test func groupIDs() {
        let g = ConversationID.newGroup()
        #expect(g.kind == .group && g.directMembers.isEmpty)
        #expect(ConversationID(rawValue: g.rawValue) == g)
        #expect(ConversationID(rawValue: "g:not-a-uuid") == nil)
    }
}

@Suite struct LamportTests {
    @Test func sendingAndReceiving() {
        #expect(Lamport.next(after: 0) == 1)
        #expect(Lamport.merge(local: 3, received: 7) == 7)
        #expect(Lamport.merge(local: 9, received: 7) == 9)
    }

    @Test func everyPhoneSortsTheSameWay() {
        let ids = (0..<6).map { _ in UUID() }
        let messages: [(lamport: UInt64, sender: String, id: UUID)] = [
            (2, nikos.rawValue, ids[0]), (1, maria.rawValue, ids[1]), (2, maria.rawValue, ids[2]),
            (3, nikos.rawValue, ids[3]), (2, maria.rawValue, ids[4]), (1, nikos.rawValue, ids[5]),
        ]
        let sorted = messages.sorted(by: Lamport.precedes)
        let reversedThenSorted = messages.reversed().sorted(by: Lamport.precedes)
        let shuffledThenSorted = messages.shuffled().sorted(by: Lamport.precedes)
        #expect(sorted.map(\.id) == reversedThenSorted.map(\.id))
        #expect(sorted.map(\.id) == shuffledThenSorted.map(\.id))
        #expect(sorted.map(\.lamport) == [1, 1, 2, 2, 2, 3])
        // Equal counters: Maria's address sorts first.
        #expect(sorted[0].sender == maria.rawValue && sorted[2].sender == maria.rawValue)
    }
}

@Suite struct EnvelopeTests {
    private func payload(_ content: MessageContent) -> Payload {
        Payload(id: UUID(), from: maria, conversation: ConversationID.direct(maria, nikos)!, group: nil,
                lamport: 4, sentAt: Date(timeIntervalSince1970: 1_764_150_000), content: content)
    }

    @Test func payloadRoundTrip() throws {
        let info = AttachmentInfo(blob: UUID(), name: "beach.jpg", mime: "image/jpeg", size: 2_400_000,
                                  source: .photos, blobSHA256: String(repeating: "0", count: 64))
        for content in [MessageContent.text("Καλησπέρα!"), .attachment(info), .pgpSetting(on: false)] {
            let p = payload(content)
            #expect(try Payload.decode(p.encoded()) == p)
        }
    }

    @Test func groupPayloadRoundTrip() throws {
        var p = payload(.text("Hi all"))
        p.conversation = .newGroup()
        p.group = GroupInfo(title: "Οικογένεια", members: [GroupMember(address: maria, name: "Μαρία", publicKey: Data([1, 2, 3]))])
        #expect(try Payload.decode(p.encoded()) == p)
    }

    @Test func unknownContentIsRejected() throws {
        let json = try String(decoding: payload(.text("x")).encoded(), as: UTF8.self)
            .replacingOccurrences(of: "\"type\":\"text\"", with: "\"type\":\"voice\"")
        #expect(throws: DecodingError.self) { try Payload.decode(Data(json.utf8)) }
    }

    @Test func envelopeChecks() throws {
        let pgp = Envelope(id: UUID(), from: maria, mode: .pgp, body: Data([9, 9]))
        #expect(try Envelope.decode(pgp.encoded()) == pgp)

        // Signed mode needs a signature; PGP mode must not carry one.
        let unsigned = Envelope(id: UUID(), from: maria, mode: .signed, body: Data([1]))
        #expect(throws: WireError.malformed) { try Envelope.decode(unsigned.encoded()) }
        let extra = Envelope(id: UUID(), from: maria, mode: .pgp, body: Data([1]), signature: Data([2]))
        #expect(throws: WireError.malformed) { try Envelope.decode(extra.encoded()) }

        var future = pgp
        future.v = 2
        #expect(throws: WireError.unsupportedVersion(2)) { try Envelope.decode(future.encoded()) }
        #expect(throws: WireError.tooLarge) { try Envelope.decode(Data(count: Envelope.maxBytes + 1)) }
    }

    @Test func attachmentDetail() {
        let info = AttachmentInfo(blob: UUID(), name: "recipe.pdf", mime: "application/pdf", size: 420_000,
                                  source: .iCloudDrive, blobSHA256: "")
        #expect(info.detail.hasSuffix(" · from iCloud Drive"))
        #expect(info.detail.contains("420"))
    }
}

@Suite struct LoopbackLayoutTests {
    let layout = LoopbackLayout(root: URL(fileURLWithPath: "/tmp/loop"))

    @Test func mailboxesComeOnlyFromLoopbackAddresses() throws {
        let box = try #require(layout.mailbox(for: maria))
        #expect(box.path == "/tmp/loop/v1/mailboxes/" + String(repeating: "a", count: 32))
        // Anything that could escape the folder, or another scheme, has no mailbox.
        for raw in ["loopback:../../etc", "loopback:" + String(repeating: "A", count: 32),
                    "loopback:abc", "icloud:" + String(repeating: "a", count: 32)] {
            #expect(layout.mailbox(for: TransportAddress(rawValue: raw)!) == nil, "\(raw)")
        }
    }

    @Test func envelopeFileNames() throws {
        let id = UUID()
        let file = try #require(layout.envelopeFile(id, for: nikos))
        #expect(LoopbackLayout.envelopeID(fromFileName: file.lastPathComponent) == id)
        #expect(LoopbackLayout.envelopeID(fromFileName: "rejected") == nil)
        #expect(LoopbackLayout.envelopeID(fromFileName: id.uuidString.uppercased() + ".json") == nil)
        #expect(LoopbackLayout.envelopeID(fromFileName: "x.json") == nil)
    }
}

@Suite struct InvitationTests {
    @Test func roundTrip() throws {
        let i = Invitation(from: maria, conversation: ConversationID.direct(maria, nikos)!, link: "https://www.icloud.com/share/0abc")
        #expect(try Invitation.decode(i.encoded()) == i)
    }
}

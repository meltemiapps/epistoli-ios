import Foundation
import Testing
@testable import EpistoliCore

@Suite struct Base45Tests {
    // Test vectors from RFC 9285 section 4.
    @Test(arguments: [("AB", "BB8"), ("Hello!!", "%69 VD92EX0"), ("base-45", "UJCLQE7W581"), ("ietf!", "QED8WEX0")])
    func rfcVectors(plain: String, encoded: String) throws {
        #expect(Base45.encode(Data(plain.utf8)) == encoded)
        #expect(try Base45.decode(encoded) == Data(plain.utf8))
    }

    @Test func rejectsBadInput() {
        #expect(throws: Base45.DecodingError.invalidLength) { try Base45.decode("A") }
        #expect(throws: Base45.DecodingError.invalidCharacter) { try Base45.decode("ab") }
        #expect(throws: Base45.DecodingError.valueOutOfRange) { try Base45.decode("GGW") }
    }

    @Test func roundTripsAllByteValues() throws {
        let data = Data((0...255).map(UInt8.init) + [0, 255, 7])
        #expect(try Base45.decode(Base45.encode(data)) == data)
    }
}

@Suite struct ContactCodeTests {
    let address = TransportAddress(rawValue: "loopback:ABCDEFGHIJKLMNOPQRSTUVWXYZ")!

    func sample(name: String = "Μαρία", keyBytes: Int = 500) -> ContactCode {
        ContactCode(fingerprint: Data((0..<20).map(UInt8.init)), address: address,
                    displayName: name, publicKey: Data((0..<keyBytes).map { UInt8($0 % 251) }))
    }

    @Test func textRoundTrip() throws {
        let code = sample()
        let text = try code.text()
        #expect(text.hasPrefix("KEY:") && text.hasSuffix("."))
        #expect(try ContactCode(text: text) == code)
    }

    @Test func textUsesOnlyQRAlphanumericCharacters() throws {
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")
        #expect(try sample().text().allSatisfy(allowed.contains))
    }

    @Test func toleratesSurroundingWhitespaceFromPasting() throws {
        let code = sample()
        #expect(try ContactCode(text: "  \n" + code.text() + "\n ") == code)
    }

    @Test func sizeForATypicalKey() throws {
        // A Curve25519 public key from GopenPGP is about 500 bytes; see docs/CONTACT_CODE.md.
        let binary = try sample().binary()
        #expect(binary.count == 1 + 20 + 1 + address.rawValue.utf8.count + 1 + "Μαρία".utf8.count + 2 + 500)
        #expect(try sample().text().count == 4 + (binary.count / 2) * 3 + (binary.count % 2) * 2 + 1)
    }

    @Test func rejectsOtherText() {
        #expect(throws: ContactCode.DecodingError.notAContactCode) { try ContactCode(text: "https://example.com") }
        #expect(throws: ContactCode.DecodingError.notAContactCode) { try ContactCode(text: "KEY:ABC") }
        #expect(throws: ContactCode.DecodingError.malformed) { try ContactCode(text: "KEY:A.") }
    }

    @Test func rejectsTruncatedAndTrailingBytes() throws {
        let binary = try sample().binary()
        #expect(throws: ContactCode.DecodingError.malformed) { try ContactCode(binary: binary.dropLast()) }
        #expect(throws: ContactCode.DecodingError.malformed) { try ContactCode(binary: binary + Data([0])) }
    }

    @Test func rejectsUnknownVersion() throws {
        var binary = try sample().binary()
        binary[0] = 2
        #expect(throws: ContactCode.DecodingError.unsupportedVersion(2)) { try ContactCode(binary: binary) }
    }

    @Test func longNamesAreCutOnACharacterBoundary() throws {
        let code = sample(name: String(repeating: "Ω", count: 40)) // 80 bytes
        let decoded = try ContactCode(binary: code.binary())
        #expect(decoded.displayName == String(repeating: "Ω", count: 32))
    }

    @Test func addressValidation() {
        #expect(TransportAddress(rawValue: "loopback:abc")?.scheme == "loopback")
        #expect(TransportAddress(rawValue: "loopback:abc")?.value == "abc")
        #expect(TransportAddress(rawValue: "noscheme") == nil)
        #expect(TransportAddress(rawValue: ":abc") == nil)
        #expect(TransportAddress(rawValue: "loopback:") == nil)
        #expect(TransportAddress(rawValue: "loop back:x") == nil)
    }
}

@Suite struct ContactRulesTests {
    let me = (fp: "ffff", address: TransportAddress(rawValue: "loopback:me")!)
    let maria = TransportAddress(rawValue: "loopback:maria")!
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 2_000)

    func offer(_ fp: String, _ source: KeySource, address: TransportAddress? = nil) -> OfferedKey {
        OfferedKey(displayName: "Maria", address: address ?? maria, fingerprint: fp, publicKey: Data(fp.utf8), source: source)
    }

    func apply(_ o: OfferedKey, to c: Contact?, sameKey: Contact? = nil, at t: Date) throws -> (contact: Contact, outcome: KeyOfferOutcome) {
        try ContactRules.apply(o, to: c, contactWithSameKey: sameKey, ownFingerprint: me.fp, ownAddress: me.address, now: t)
    }

    @Test func scannedInPersonIsVerifiedPastedIsNot() throws {
        let scanned = try apply(offer("aaaa", .scannedInPerson), to: nil, at: t0)
        #expect(scanned.outcome == .added && scanned.contact.verification == .verified)
        let pasted = try apply(offer("aaaa", .receivedOtherwise), to: nil, at: t0)
        #expect(pasted.outcome == .added && pasted.contact.verification == .unverified)
        #expect(!pasted.contact.needsKeyChangeWarning)
    }

    @Test func rescanningInPersonVerifies() throws {
        let pasted = try apply(offer("aaaa", .receivedOtherwise), to: nil, at: t0).contact
        let r = try apply(offer("aaaa", .scannedInPerson), to: pasted, at: t1)
        #expect(r.outcome == .verified && r.contact.verification == .verified)
        #expect(r.contact.keys.count == 1 && r.contact.currentKey.firstSeen == t0)
        // Pasting the same key again never downgrades.
        let again = try apply(offer("aaaa", .receivedOtherwise), to: r.contact, at: t1)
        #expect(again.outcome == .unchanged && again.contact.verification == .verified)
    }

    @Test func keyChangeKeepsHistoryAndWarns() throws {
        let verified = try apply(offer("aaaa", .scannedInPerson), to: nil, at: t0).contact
        let r = try apply(offer("bbbb", .receivedOtherwise), to: verified, at: t1)
        #expect(r.outcome == .keyChanged(warning: true))
        #expect(r.contact.id == verified.id)
        #expect(r.contact.keys.map(\.fingerprint) == ["aaaa", "bbbb"])
        #expect(r.contact.keys[0].replacedAt == t1 && r.contact.keys[1].replacedAt == nil)
        #expect(r.contact.verification == .unverified)
        #expect(r.contact.needsKeyChangeWarning)
    }

    @Test func scanningTheNewKeyInPersonClearsTheWarning() throws {
        let first = try apply(offer("aaaa", .scannedInPerson), to: nil, at: t0).contact
        let changed = try apply(offer("bbbb", .receivedOtherwise), to: first, at: t1).contact
        let r = try apply(offer("bbbb", .scannedInPerson), to: changed, at: t1)
        #expect(r.outcome == .verified && !r.contact.needsKeyChangeWarning && r.contact.verification == .verified)
    }

    /// Security: accepting a changed key from a pasted code keeps the contact Unverified with the
    /// key-change banner, through any number of further pastes, until the camera scans the key.
    @Test func pastedKeyChangeStaysUnverifiedUntilCameraScan() throws {
        let verified = try apply(offer("aaaa", .scannedInPerson), to: nil, at: t0).contact
        #expect(verified.verification == .verified)

        var r = try apply(offer("bbbb", .receivedOtherwise), to: verified, at: t1)
        #expect(r.outcome == .keyChanged(warning: true))
        #expect(r.contact.verification == .unverified && r.contact.needsKeyChangeWarning)

        // Pasting the same new key again changes nothing.
        r = try apply(offer("bbbb", .receivedOtherwise), to: r.contact, at: t1)
        #expect(r.outcome == .unchanged)
        #expect(r.contact.verification == .unverified && r.contact.needsKeyChangeWarning)

        // Pasting the old, once-verified key back is another change, not a restore.
        r = try apply(offer("aaaa", .receivedOtherwise), to: r.contact, at: t1)
        #expect(r.outcome == .keyChanged(warning: true))
        #expect(r.contact.verification == .unverified && r.contact.needsKeyChangeWarning)
        #expect(r.contact.keys.map(\.fingerprint) == ["aaaa", "bbbb", "aaaa"])

        // Only the camera restores Verified and clears the banner.
        r = try apply(offer("aaaa", .scannedInPerson), to: r.contact, at: t1)
        #expect(r.outcome == .verified)
        #expect(r.contact.verification == .verified && !r.contact.needsKeyChangeWarning)
    }

    /// Security: a camera scan of a key different from the pending one also ends the warning,
    /// because the camera scan is itself the in-person check.
    @Test func cameraScanOfAnotherKeyRestoresVerified() throws {
        let first = try apply(offer("aaaa", .scannedInPerson), to: nil, at: t0).contact
        let changed = try apply(offer("bbbb", .receivedOtherwise), to: first, at: t1).contact
        let r = try apply(offer("cccc", .scannedInPerson), to: changed, at: t1)
        #expect(r.outcome == .keyChanged(warning: false))
        #expect(r.contact.verification == .verified && !r.contact.needsKeyChangeWarning)
    }

    @Test func pendingKeyChangeIsNeverVerified() {
        let inconsistent = Contact(displayName: "Maria", address: maria,
                                   keys: [ContactKey(fingerprint: "aaaa", publicKey: Data(), source: .scannedInPerson, firstSeen: t0)],
                                   keyChangedAt: t1)
        #expect(inconsistent.verification == .unverified)
    }

    @Test func newKeyScannedInPersonNeedsNoWarning() throws {
        let first = try apply(offer("aaaa", .scannedInPerson), to: nil, at: t0).contact
        let r = try apply(offer("bbbb", .scannedInPerson), to: first, at: t1)
        #expect(r.outcome == .keyChanged(warning: false) && !r.contact.needsKeyChangeWarning)
        #expect(r.contact.keys.count == 2)
    }

    @Test func refusesOwnCodeAndKeysOfOtherContacts() throws {
        #expect(throws: KeyOfferError.ownCode) { try apply(offer("FFFF", .scannedInPerson), to: nil, at: t0) }
        #expect(throws: KeyOfferError.ownCode) { try apply(offer("aaaa", .scannedInPerson, address: me.address), to: nil, at: t0) }
        let nikos = Contact(displayName: "Nikos", address: TransportAddress(rawValue: "loopback:nikos")!,
                            keys: [ContactKey(fingerprint: "aaaa", publicKey: Data(), source: .scannedInPerson, firstSeen: t0)])
        #expect(throws: KeyOfferError.keyBelongsToAnotherContact(name: "Nikos")) {
            try apply(offer("aaaa", .scannedInPerson), to: nil, sameKey: nikos, at: t0)
        }
    }
}

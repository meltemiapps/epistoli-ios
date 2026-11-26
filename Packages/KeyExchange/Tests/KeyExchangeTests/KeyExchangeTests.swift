import Foundation
import GRDB
import Testing
import EpistoliCore
import SealedCrypto
import SealedStorage
import KeyExchangeTestSupport
@testable import KeyExchange

private func identityStore() throws -> (IdentityStore, MemorySecretStore, SecureEnclaveKeyWrapper) {
    let secrets = MemorySecretStore()
    let wrapper = try SecureEnclaveKeyWrapper.ephemeral()
    return (IdentityStore(store: secrets, wrapper: wrapper), secrets, wrapper)
}

private func database() throws -> DatabasePool {
    var migrator = DatabaseMigrator()
    ContactStore.registerMigrations(in: &migrator)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kx-\(UUID().uuidString).sqlite")
    return try SealedDatabase.open(at: url, key: try DatabaseKeyProvider(store: MemorySecretStore(), wrapper: SecureEnclaveKeyWrapper.ephemeral()).key(), migrator: migrator)
}

private func scanner(_ identity: Identity) -> PrivateKeyLeakScanner {
    PrivateKeyLeakScanner(privateKey: identity.privateKey, publicKey: identity.publicKey)
}

@Suite struct IdentityStoreTests {
    @Test func createThenLoad() throws {
        let (store, _, _) = try identityStore()
        #expect(try store.load() == nil)
        let created = try store.create(displayName: "  Μαρία  ")
        let loaded = try #require(try store.load())
        #expect(loaded.displayName == "Μαρία")
        #expect(loaded.address == created.address && loaded.address.scheme == "loopback")
        #expect(loaded.fingerprint == created.fingerprint)
        #expect(loaded.privateKey.data == created.privateKey.data)
    }

    @Test func privateKeyIsStoredOnlyWrapped() throws {
        let (store, secrets, wrapper) = try identityStore()
        let identity = try store.create(displayName: "Maria")
        let stored = try #require(try secrets.data(for: IdentityStore.keyAccount))
        #expect(stored != identity.privateKey.data)
        #expect(scanner(identity).encodingsFound(in: stored).isEmpty, "the stored item must be ciphertext")
        #expect(try wrapper.unwrap(stored) == identity.privateKey.data)
        // The profile item holds only the name and address.
        let profile = try #require(try secrets.data(for: IdentityStore.profileAccount))
        #expect(scanner(identity).encodingsFound(in: profile).isEmpty)
    }

    @Test func emptyNameIsRefused() throws {
        let (store, _, _) = try identityStore()
        #expect(throws: IdentityError.emptyName) { try store.create(displayName: "   ") }
    }

    @Test func replacingTheKeyKeepsNameAndAddress() throws {
        let (store, _, _) = try identityStore()
        let old = try store.create(displayName: "Maria")
        let new = try store.replaceKey(of: old)
        #expect(new.address == old.address && new.displayName == old.displayName)
        #expect(new.fingerprint != old.fingerprint)
        #expect(try store.load()?.fingerprint == new.fingerprint)
    }
}

@Suite struct ContactCodecTests {
    @Test func myCodeRoundTripsAndHoldsNoPrivateKey() throws {
        let (store, _, _) = try identityStore()
        let me = try store.create(displayName: "Μαρία Παπαδοπούλου")
        let text = try ContactCodec.code(for: me)
        #expect(scanner(me).findings(inText: text, location: "code").isEmpty)
        let binary = try ContactCode(text: text).binary()
        #expect(scanner(me).encodingsFound(in: binary).isEmpty)

        let offer = try ContactCodec.read(text, source: .receivedOtherwise)
        #expect(offer.fingerprint == me.fingerprint.hex)
        #expect(offer.address == me.address)
        #expect(offer.displayName == "Μαρία Παπαδοπούλου")
        #expect(offer.publicKey == me.publicKey.data)
        // Reported in docs/CONTACT_CODE.md: about 600 bytes binary, 900 characters, QR version 19 at level M.
        print("contact code: binary \(binary.count) bytes, text \(text.count) characters, key \(me.publicKey.data.count) bytes")
        #expect(text.count < 1000)
    }

    @Test func aCodeCarryingAPrivateKeyIsRejected() throws {
        let (store, _, _) = try identityStore()
        let me = try store.create(displayName: "Maria")
        let evil = try ContactCode(fingerprint: Data(hex: me.fingerprint.hex)!, address: me.address,
                                   displayName: "Maria", publicKey: me.privateKey.data).text()
        #expect(throws: ContactCodeError.invalidKey) { try ContactCodec.read(evil, source: .scannedInPerson) }
    }

    @Test func fingerprintMustMatchTheKey() throws {
        let (store, _, _) = try identityStore()
        let me = try store.create(displayName: "Maria")
        let other = try SealedCrypto.publicKey(of: SealedCrypto.generateIdentity(name: "x"))
        let forged = try ContactCode(fingerprint: Data(hex: other.fingerprint.hex)!, address: me.address,
                                     displayName: "Maria", publicKey: me.publicKey.data).text()
        #expect(throws: ContactCodeError.fingerprintMismatch) { try ContactCodec.read(forged, source: .scannedInPerson) }
    }

    @Test func otherQRCodesAreNotContactCodes() {
        #expect(throws: ContactCodeError.notAContactCode) { try ContactCodec.read("https://example.com", source: .scannedInPerson) }
        #expect(throws: ContactCodeError.damaged) { try ContactCodec.read("KEY:0000.", source: .scannedInPerson) }
    }
}

@Suite struct ContactStoreTests {
    @Test func addVerifyChangeAndPersistHistory() throws {
        let (myStore, _, _) = try identityStore()
        let me = try myStore.create(displayName: "Me")
        let (mariaStore, _, _) = try identityStore()
        let maria = try mariaStore.create(displayName: "Maria")
        let pool = try database()
        let contacts = ContactStore(db: pool)

        let pasted = try ContactCodec.read(try ContactCodec.code(for: maria), source: .receivedOtherwise)
        #expect(try contacts.offer(pasted, from: me).outcome == .added)
        #expect(try contacts.all().first?.verification == .unverified)

        let scanned = try ContactCodec.read(try ContactCodec.code(for: maria), source: .scannedInPerson)
        #expect(try contacts.offer(scanned, from: me).outcome == .verified)
        #expect(try contacts.all().first?.verification == .verified)

        // Maria gets a new phone: new key, same address. Received as a pasted code.
        let newMaria = try mariaStore.replaceKey(of: maria)
        let changed = try ContactCodec.read(try ContactCodec.code(for: newMaria), source: .receivedOtherwise)
        #expect(try contacts.offer(changed, from: me).outcome == .keyChanged(warning: true))

        let stored = try #require(try contacts.all().first)
        #expect(try contacts.all().count == 1)
        #expect(stored.needsKeyChangeWarning)
        #expect(stored.keys.map(\.fingerprint) == [maria.fingerprint.hex, newMaria.fingerprint.hex])
        #expect(stored.keys[0].source == .scannedInPerson && stored.keys[0].replacedAt != nil)
        #expect(stored.currentKey.source == .receivedOtherwise)
        #expect(try contacts.contact(id: stored.id) == stored)
    }

    /// Security, both paths, through the database: a pasted key change is saved Unverified with the
    /// banner flag and stays that way; a camera scan saves it Verified and clears the flag.
    @Test func pastedKeyChangePersistsUnverifiedUntilCameraScan() throws {
        let (myStore, _, _) = try identityStore()
        let me = try myStore.create(displayName: "Me")
        let (mariaStore, _, _) = try identityStore()
        let maria = try mariaStore.create(displayName: "Maria")
        let pool = try database()

        try ContactStore(db: pool).offer(try ContactCodec.read(try ContactCodec.code(for: maria), source: .scannedInPerson), from: me)
        let newMaria = try mariaStore.replaceKey(of: maria)
        let newCode = try ContactCodec.code(for: newMaria)

        // Path 1: accept the new key from a pasted code. A fresh store reads it back from the file.
        try ContactStore(db: pool).offer(try ContactCodec.read(newCode, source: .receivedOtherwise), from: me)
        var stored = try #require(try ContactStore(db: pool).all().first)
        #expect(stored.currentKey.fingerprint == newMaria.fingerprint.hex)
        #expect(stored.verification == .unverified && stored.needsKeyChangeWarning)

        // Pasting it again does not help.
        #expect(try ContactStore(db: pool).offer(try ContactCodec.read(newCode, source: .receivedOtherwise), from: me).outcome == .unchanged)
        stored = try #require(try ContactStore(db: pool).all().first)
        #expect(stored.verification == .unverified && stored.needsKeyChangeWarning)

        // Path 2: scan the same code with the camera.
        #expect(try ContactStore(db: pool).offer(try ContactCodec.read(newCode, source: .scannedInPerson), from: me).outcome == .verified)
        stored = try #require(try ContactStore(db: pool).all().first)
        #expect(stored.verification == .verified && !stored.needsKeyChangeWarning)
        #expect(stored.keys.count == 2)
    }

    @Test func ownCodeIsRefused() throws {
        let (store, _, _) = try identityStore()
        let me = try store.create(displayName: "Me")
        let contacts = ContactStore(db: try database())
        let offer = try ContactCodec.read(try ContactCodec.code(for: me), source: .scannedInPerson)
        #expect(throws: KeyOfferError.ownCode) { try contacts.offer(offer, from: me) }
    }

    @Test func renameKeepsNameAcrossKeyChanges() throws {
        let (myStore, _, _) = try identityStore()
        let me = try myStore.create(displayName: "Me")
        let (mariaStore, _, _) = try identityStore()
        let maria = try mariaStore.create(displayName: "Maria")
        let contacts = ContactStore(db: try database())
        let added = try contacts.offer(try ContactCodec.read(try ContactCodec.code(for: maria), source: .scannedInPerson), from: me)
        try contacts.rename(added.contact.id, to: "Μαμά")
        let newMaria = try mariaStore.replaceKey(of: maria)
        try contacts.offer(try ContactCodec.read(try ContactCodec.code(for: newMaria), source: .scannedInPerson), from: me)
        #expect(try contacts.all().first?.displayName == "Μαμά")
    }

    @Test func databaseNeverHoldsMyPrivateKey() throws {
        let (myStore, _, _) = try identityStore()
        let me = try myStore.create(displayName: "Me")
        let (mariaStore, _, _) = try identityStore()
        let maria = try mariaStore.create(displayName: "Maria")
        let pool = try database()
        try ContactStore(db: pool).offer(try ContactCodec.read(try ContactCodec.code(for: maria), source: .scannedInPerson), from: me)
        let result = try scanner(me).scanDatabase(pool)
        #expect(result.valuesScanned > 0)
        #expect(result.findings.isEmpty, "\(result.findings)")
    }
}

@Suite struct LeakScannerTests {
    /// Positive control: the scanner must find the key in every encoding it claims to cover.
    @Test func findsPlantedKeysInEveryEncoding() throws {
        let (store, _, _) = try identityStore()
        let me = try store.create(displayName: "Me")
        let s = scanner(me)
        #expect(s.needleCount > 10)
        let raw = me.privateKey.data
        let padding = Data("prefix ".utf8)
        #expect(s.encodingsFound(in: padding + raw + padding).contains("binary"))
        #expect(s.encodingsFound(in: Data(raw.map { String(format: "%02x", $0) }.joined().utf8)).contains("hex"))
        #expect(s.encodingsFound(in: Data(raw.map { String(format: "%02X", $0) }.joined().utf8)).contains("hex"))
        for offset in 0..<3 {
            let b64 = (Data(repeating: 0x41, count: offset) + raw).base64EncodedString(options: .lineLength64Characters)
            #expect(s.encodingsFound(in: Data(b64.utf8)).contains("base64"), "alignment \(offset)")
        }
        #expect(s.encodingsFound(in: Data("-----BEGIN PGP PRIVATE KEY BLOCK-----".utf8)).contains("armour"))
    }

    @Test func publicKeyIsNotALeak() throws {
        let (store, _, _) = try identityStore()
        let me = try store.create(displayName: "Me")
        let s = scanner(me)
        #expect(s.encodingsFound(in: me.publicKey.data).isEmpty)
        #expect(s.findings(inText: try SealedCrypto.armored(me.publicKey), location: "armoured public key").isEmpty)
        #expect(s.encodingsFound(in: Data(me.publicKey.data.base64EncodedString().utf8)).isEmpty)
    }
}

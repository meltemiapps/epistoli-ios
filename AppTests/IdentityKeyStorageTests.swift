import Foundation
import OSLog
import Security
import Testing
import EpistoliCore
import KeyExchange
import KeyExchangeTestSupport
import SealedCrypto
import SealedStorage
@testable import Epistoli

/// The identity private key must be stored exactly like the database key: a Keychain item,
/// `WhenUnlockedThisDeviceOnly`, wrapped by the Secure Enclave key (software key on the simulator),
/// and never written to the database, to files in the app container, to logs or into an export.
///
/// Runs in the app host so the real Keychain, the real `AppEnvironment` wiring and the real app
/// container are used. On a device it is the Checkpoint E check in docs/DEVICE_TEST_CHECKLIST.md.
@Suite(.serialized) struct IdentityKeyStorageTests {
    private struct Fixture {
        let env: AppEnvironment
        let me: Identity
        let directory: URL
        let service: String
        let tag: String

        init() throws {
            let id = UUID().uuidString
            service = "tests.identity.\(id)"
            tag = "tests.identity.wrap.\(id)"
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
            directory = support.appendingPathComponent("tests-\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            env = try AppEnvironment.make(service: service, wrapperTag: tag,
                                          databaseURL: directory.appendingPathComponent("store.sqlite"))
            me = try env.identities.create(displayName: "Μαρία")
        }

        func tearDown() {
            try? env.secrets.delete(IdentityStore.keyAccount)
            try? env.secrets.delete(IdentityStore.profileAccount)
            try? env.secrets.delete(DatabaseKeyProvider.account)
            SecureEnclaveKeyWrapper.deleteKey(tag: tag)
            try? FileManager.default.removeItem(at: directory)
        }

        var scanner: PrivateKeyLeakScanner { PrivateKeyLeakScanner(privateKey: me.privateKey, publicKey: me.publicKey) }
    }

    @Test func privateKeyIsAWrappedKeychainItemWhenUnlockedThisDeviceOnly() throws {
        let f = try Fixture()
        defer { f.tearDown() }

        let stored = try #require(try f.env.secrets.data(for: IdentityStore.keyAccount))
        #expect(try f.env.secrets.accessibility(of: IdentityStore.keyAccount) == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(try f.env.secrets.accessibility(of: DatabaseKeyProvider.account) == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(f.scanner.encodingsFound(in: stored).isEmpty, "the Keychain item must hold only the wrapped key")

        // The same wrapping key that protects the database key opens it, after a "relaunch".
        let wrapper = try SecureEnclaveKeyWrapper(tag: f.tag)
        #expect(try wrapper.unwrap(stored) == f.me.privateKey.data)
        let reloaded = try #require(try AppEnvironment.make(service: f.service, wrapperTag: f.tag,
                                                            databaseURL: f.directory.appendingPathComponent("store.sqlite")).identities.load())
        #expect(reloaded.fingerprint == f.me.fingerprint)

        let tokenID = try SecureEnclaveKeyWrapper.storedKeyTokenID(tag: f.tag)
        #if targetEnvironment(simulator)
        #expect(tokenID == nil, "simulator uses the software fallback")
        #else
        #expect(tokenID == kSecAttrTokenIDSecureEnclave as String,
                "device must wrap the identity key with a Secure Enclave key, got \(tokenID ?? "software key")")
        #endif
    }

    @Test func privateKeyIsNeverInTheDatabaseContainerLogsOrExports() throws {
        let start = Date().addingTimeInterval(-1)
        let f = try Fixture()
        defer { f.tearDown() }
        let scanner = f.scanner

        // Exercise every path that touches keys: export my code, add a contact from a code, save contacts.
        let code = try ContactCodec.code(for: f.me)
        let armored = try SealedCrypto.armored(f.me.publicKey)
        let maria = try IdentityStore(store: MemorySecretStore(), wrapper: SecureEnclaveKeyWrapper.ephemeral()).create(displayName: "Maria")
        try f.env.contacts.offer(try ContactCodec.read(try ContactCodec.code(for: maria), source: .scannedInPerson), from: f.me)
        UserDefaults.standard.synchronize()

        // Exports.
        #expect(scanner.findings(inText: code, location: "My code").isEmpty)
        #expect(scanner.findings(inText: armored, location: "armoured public key").isEmpty)

        // The database, decrypted: every text and blob value in every table.
        let db = try scanner.scanDatabase(f.env.database)
        #expect(db.valuesScanned > 0)
        #expect(db.findings.isEmpty, "\(db.findings)")

        // Every file in the app container: the SQLCipher file and its WAL, preferences, caches, tmp.
        let container = URL(fileURLWithPath: NSHomeDirectory())
        #expect(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("store.sqlite").path))
        let files = try scanner.scanFiles(under: container)
        #expect(files.filesScanned > 0)
        #expect(files.findings.isEmpty, "\(files.findings)")

        // This process's log, which includes everything the app logged while creating the key.
        let log = try OSLogStore(scope: .currentProcessIdentifier)
        let messages = try log.getEntries(at: log.position(date: start)).map(\.composedMessage)
        #expect(messages.contains { $0.contains(f.me.fingerprint.hex) }, "the key-creation log line should be captured")
        let logFindings = messages.flatMap { scanner.findings(inText: $0, location: "log") }
        #expect(logFindings.isEmpty, "\(logFindings)")
    }

    /// Positive control: the container scan does find a key that is written to a file.
    @Test func containerScanFindsAPlantedKey() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let planted = f.directory.appendingPathComponent("planted.bin")
        try (Data("x".utf8) + f.me.privateKey.data).write(to: planted)
        let armour = f.directory.appendingPathComponent("planted.txt")
        try f.me.privateKey.data.base64EncodedString(options: .lineLength64Characters).write(to: armour, atomically: true, encoding: .utf8)
        let found = try f.scanner.scanFiles(under: URL(fileURLWithPath: NSHomeDirectory())).findings
        #expect(found.contains { $0.location.hasSuffix("planted.bin") && $0.encoding == "binary" })
        #expect(found.contains { $0.location.hasSuffix("planted.txt") && $0.encoding == "base64" })
    }
}

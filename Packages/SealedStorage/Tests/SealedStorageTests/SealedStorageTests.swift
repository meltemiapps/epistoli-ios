import Foundation
import GRDB
import Testing
@testable import SealedStorage

@Suite struct SealedStorageTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sealed-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "note") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("body", .text).notNull()
            }
        }
        return m
    }

    @Test func sqlCipherIsLinked() throws {
        let version = try SealedDatabase.cipherVersion()
        #expect(version?.hasPrefix("4.") == true)
    }

    @Test func roundTripWithKey() throws {
        let url = tempURL()
        let key = try DatabaseKeyProvider.randomBytes(32)
        do {
            let db = try SealedDatabase.open(at: url, key: key, migrator: migrator)
            try db.write { try $0.execute(sql: "INSERT INTO note (body) VALUES (?)", arguments: ["secret text"]) }
        }
        let reopened = try SealedDatabase.open(at: url, key: key, migrator: migrator)
        #expect(try reopened.read { try String.fetchOne($0, sql: "SELECT body FROM note") } == "secret text")
    }

    @Test func wontOpenWithoutTheKey() throws {
        let url = tempURL()
        let key = try DatabaseKeyProvider.randomBytes(32)
        do {
            let db = try SealedDatabase.open(at: url, key: key, migrator: migrator)
            try db.write { try $0.execute(sql: "INSERT INTO note (body) VALUES ('x')") }
        }
        // No key at all: plain SQLite cannot read it.
        #expect(throws: (any Error).self) {
            let plain = try DatabaseQueue(path: url.path)
            _ = try plain.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_master") }
        }
        // Wrong key.
        #expect(throws: SealedStorageError.databaseLocked) {
            _ = try SealedDatabase.open(at: url, key: try DatabaseKeyProvider.randomBytes(32), migrator: migrator)
        }
    }

    @Test func fileIsNotPlainSQLite() throws {
        let url = tempURL()
        do {
            let db = try SealedDatabase.open(at: url, key: try DatabaseKeyProvider.randomBytes(32), migrator: migrator)
            try db.write { try $0.execute(sql: "INSERT INTO note (body) VALUES ('findme-plaintext')") }
        }
        let bytes = try Data(contentsOf: url)
        #expect(!bytes.starts(with: Data("SQLite format 3".utf8)))
        #expect(bytes.range(of: Data("findme-plaintext".utf8)) == nil)
    }

    @Test func keyWrapRoundTrip() throws {
        let wrapper = try SecureEnclaveKeyWrapper.ephemeral()
        let secret = try DatabaseKeyProvider.randomBytes(32)
        let wrapped = try wrapper.wrap(secret)
        #expect(wrapped != secret)
        #expect(try wrapper.unwrap(wrapped) == secret)
    }

    @Test func otherWrapperCannotUnwrap() throws {
        let wrapped = try SecureEnclaveKeyWrapper.ephemeral().wrap(Data(repeating: 7, count: 32))
        #expect(throws: SealedStorageError.self) { try SecureEnclaveKeyWrapper.ephemeral().unwrap(wrapped) }
    }

    @Test func keyProviderIsStableAndStoresOnlyWrappedKey() throws {
        let store = MemorySecretStore()
        let provider = DatabaseKeyProvider(store: store, wrapper: try SecureEnclaveKeyWrapper.ephemeral())
        let first = try provider.key()
        #expect(first.count == 32)
        #expect(try provider.key() == first)
        let stored = try #require(try store.data(for: DatabaseKeyProvider.account))
        #expect(stored != first)
        #expect(stored.range(of: first) == nil)
    }

    @Test func lostWrappingKeyMeansNoDatabase() throws {
        let store = MemorySecretStore()
        let url = tempURL()
        let key = try DatabaseKeyProvider(store: store, wrapper: try SecureEnclaveKeyWrapper.ephemeral()).key()
        _ = try SealedDatabase.open(at: url, key: key, migrator: migrator)
        // A different wrapping key (e.g. the Secure Enclave key is gone) cannot recover the database key.
        #expect(throws: SealedStorageError.self) {
            _ = try DatabaseKeyProvider(store: store, wrapper: try SecureEnclaveKeyWrapper.ephemeral()).key()
        }
    }
}

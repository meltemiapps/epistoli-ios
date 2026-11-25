import Foundation
import GRDB

/// Opens SQLCipher-encrypted databases.
public enum SealedDatabase {
    /// Opens (or creates) the database at `url`, encrypted with a raw 32-byte key, and runs `migrator`.
    /// Throws `SealedStorageError.databaseLocked` if the key is wrong or the file is not ours.
    public static func open(at url: URL, key: Data, migrator: DatabaseMigrator = DatabaseMigrator()) throws -> DatabasePool {
        precondition(key.count == 32, "SQLCipher raw key must be 32 bytes")
        var config = Configuration()
        let rawKey = "x'" + key.map { String(format: "%02X", $0) }.joined() + "'"
        config.prepareDatabase { db in
            // A blob literal passed to sqlite3_key is used as the raw key (no PBKDF2).
            try db.usePassphrase(rawKey)
            try db.execute(sql: "PRAGMA cipher_memory_security = ON")
        }
        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: url.path, configuration: config)
            // Force a read so a wrong key fails here, not later.
            _ = try pool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_master") }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
            throw SealedStorageError.databaseLocked
        }
        try migrator.migrate(pool)
        return pool
    }

    /// The SQLCipher version linked into the app.
    public static func cipherVersion() throws -> String? {
        let queue = try DatabaseQueue()
        return try queue.read { try String.fetchOne($0, sql: "PRAGMA cipher_version") }
    }
}

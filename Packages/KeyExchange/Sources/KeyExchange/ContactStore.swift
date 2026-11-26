import Foundation
import GRDB
import EpistoliCore

/// Contacts and their key history, in the SQLCipher database. Public keys only.
public final class ContactStore: Sendable {
    private let db: any DatabaseWriter

    public init(db: any DatabaseWriter) {
        self.db = db
    }

    /// Adds this store's tables to the app's migrator. Migration names must never change.
    public static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("contacts.v1") { db in
            try db.create(table: "contact") { t in
                t.primaryKey("id", .text)
                t.column("displayName", .text).notNull()
                t.column("address", .text).notNull().unique()
                t.column("keyChangedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "contactKey") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("contact", onDelete: .cascade).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("publicKey", .blob).notNull()
                t.column("source", .text).notNull()
                t.column("firstSeen", .datetime).notNull()
                t.column("replacedAt", .datetime)
            }
            try db.create(index: "contactKey_fingerprint", on: "contactKey", columns: ["fingerprint"])
        }
    }

    /// Every contact, by name.
    public func all() throws -> [Contact] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM contact ORDER BY displayName COLLATE NOCASE, createdAt")
                .map { try Self.contact(from: $0, in: db) }
        }
    }

    public func contact(id: UUID) throws -> Contact? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM contact WHERE id = ?", arguments: [id.uuidString])
                .map { try Self.contact(from: $0, in: db) }
        }
    }

    /// Applies a scanned or pasted key (see `ContactRules`) and saves the result, atomically.
    @discardableResult
    public func offer(_ offer: OfferedKey, from me: Identity, now: Date = Date()) throws -> (contact: Contact, outcome: KeyOfferOutcome) {
        try db.write { db in
            let existing = try Row.fetchOne(db, sql: "SELECT * FROM contact WHERE address = ?", arguments: [offer.address.rawValue])
                .map { try Self.contact(from: $0, in: db) }
            let sameKey = try Row.fetchOne(db, sql: """
                SELECT contact.* FROM contact JOIN contactKey ON contactKey.contactId = contact.id
                WHERE contactKey.fingerprint = ? AND contactKey.replacedAt IS NULL LIMIT 1
                """, arguments: [offer.fingerprint])
                .map { try Self.contact(from: $0, in: db) }
            let result = try ContactRules.apply(offer, to: existing, contactWithSameKey: sameKey,
                                                ownFingerprint: me.fingerprint.hex, ownAddress: me.address, now: now)
            try Self.save(result.contact, isNew: existing == nil, now: now, in: db)
            return result
        }
    }

    public func rename(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try db.write { try $0.execute(sql: "UPDATE contact SET displayName = ? WHERE id = ?", arguments: [trimmed, id.uuidString]) }
    }

    public func delete(_ id: UUID) throws {
        try db.write { try $0.execute(sql: "DELETE FROM contact WHERE id = ?", arguments: [id.uuidString]) }
    }

    // MARK: Rows

    private static func save(_ contact: Contact, isNew: Bool, now: Date, in db: Database) throws {
        if isNew {
            try db.execute(sql: "INSERT INTO contact (id, displayName, address, keyChangedAt, createdAt) VALUES (?, ?, ?, ?, ?)",
                           arguments: [contact.id.uuidString, contact.displayName, contact.address.rawValue, contact.keyChangedAt, now])
        } else {
            // The scanner may have renamed the contact; a code's name never overwrites it.
            try db.execute(sql: "UPDATE contact SET keyChangedAt = ? WHERE id = ?",
                           arguments: [contact.keyChangedAt, contact.id.uuidString])
        }
        // Rewrite the history: it is small (a few keys) and this keeps rows and model identical.
        try db.execute(sql: "DELETE FROM contactKey WHERE contactId = ?", arguments: [contact.id.uuidString])
        for key in contact.keys {
            try db.execute(sql: """
                INSERT INTO contactKey (contactId, fingerprint, publicKey, source, firstSeen, replacedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [contact.id.uuidString, key.fingerprint, key.publicKey, key.source.rawValue, key.firstSeen, key.replacedAt])
        }
    }

    private static func contact(from row: Row, in db: Database) throws -> Contact {
        let id: String = row["id"]
        let keys = try Row.fetchAll(db, sql: "SELECT * FROM contactKey WHERE contactId = ? ORDER BY id", arguments: [id]).map { k in
            ContactKey(fingerprint: k["fingerprint"], publicKey: k["publicKey"],
                       source: KeySource(rawValue: k["source"]) ?? .receivedOtherwise,
                       firstSeen: k["firstSeen"], replacedAt: k["replacedAt"])
        }
        guard let uuid = UUID(uuidString: id), let address = TransportAddress(rawValue: row["address"]), !keys.isEmpty else {
            throw DatabaseError(message: "corrupt contact row \(id)")
        }
        return Contact(id: uuid, displayName: row["displayName"], address: address, keys: keys, keyChangedAt: row["keyChangedAt"])
    }
}

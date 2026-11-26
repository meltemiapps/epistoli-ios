import Foundation
import GRDB
import EpistoliCore

/// A chat as this phone sees it.
public struct Conversation: Equatable, Sendable, Identifiable {
    public var id: ConversationID
    /// Groups only; a direct chat shows the contact's name.
    public var title: String?
    /// Everyone except us.
    public var members: [TransportAddress]
    /// PGP for the messages we send (on by default). Shared: changing it tells the other members.
    public var pgp: Bool
    /// The highest Lamport counter seen in this chat.
    public var lamport: UInt64
    public var lastActivity: Date
    public var lastMessage: ChatMessage?

    public var kind: ConversationKind { id.kind }
}

public struct ChatMessage: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var conversation: ConversationID
    public var sender: TransportAddress
    public var outgoing: Bool
    public var lamport: UInt64
    public var sentAt: Date
    /// Whether this message travelled PGP-encrypted (`false`: signed, TLS only).
    public var pgp: Bool
    public var content: MessageContent

    var orderKey: (lamport: UInt64, sender: String, id: UUID) { (lamport, sender.rawValue, id) }
}

/// Conversations, messages and attachments, in the SQLCipher database next to the contacts.
/// Attachments are kept decrypted only inside the encrypted database.
public final class ConversationStore: Sendable {
    private let db: any DatabaseWriter

    public init(db: any DatabaseWriter) { self.db = db }

    /// Adds this store's tables to the app's migrator. Migration names must never change.
    public static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("messaging.v1") { db in
            try db.create(table: "conversation") { t in
                t.primaryKey("id", .text)
                t.column("title", .text)
                t.column("pgp", .boolean).notNull()
                t.column("pgpLamport", .integer).notNull().defaults(to: 0)
                t.column("lamport", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastActivity", .datetime).notNull()
            }
            try db.create(table: "conversationMember") { t in
                t.belongsTo("conversation", onDelete: .cascade).notNull()
                t.column("address", .text).notNull()
                t.primaryKey(["conversationId", "address"])
            }
            try db.create(table: "attachment") { t in
                t.primaryKey("id", .text)
                t.column("data", .blob).notNull()
            }
            try db.create(table: "message") { t in
                t.primaryKey("id", .text)
                t.belongsTo("conversation", onDelete: .cascade).notNull()
                t.column("sender", .text).notNull()
                t.column("outgoing", .boolean).notNull()
                t.column("lamport", .integer).notNull()
                t.column("sentAt", .datetime).notNull()
                t.column("receivedAt", .datetime).notNull()
                t.column("pgp", .boolean).notNull()
                t.column("content", .blob).notNull()
                t.column("attachmentId", .text).references("attachment", onDelete: .setNull)
            }
            try db.create(index: "message_order", on: "message", columns: ["conversationId", "lamport"])
        }
    }

    // MARK: Reading

    /// Every conversation, most recent first, each with its last message.
    public func conversations() throws -> [Conversation] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM conversation ORDER BY lastActivity DESC").map { try Self.conversation($0, in: db) }
        }
    }

    public func conversation(_ id: ConversationID) throws -> Conversation? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM conversation WHERE id = ?", arguments: [id.rawValue]).map { try Self.conversation($0, in: db) }
        }
    }

    /// Messages in display order (`Lamport.precedes`).
    public func messages(in id: ConversationID) throws -> [ChatMessage] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM message WHERE conversationId = ?", arguments: [id.rawValue])
                .map(Self.message)
                .sorted { Lamport.precedes($0.orderKey, $1.orderKey) }
        }
    }

    public func attachmentData(_ blob: UUID) throws -> Data? {
        try db.read { try Data.fetchOne($0, sql: "SELECT data FROM attachment WHERE id = ?", arguments: [blob.uuidString]) }
    }

    public func hasMessage(_ id: UUID) throws -> Bool {
        try db.read { try Bool.fetchOne($0, sql: "SELECT 1 FROM message WHERE id = ?", arguments: [id.uuidString]) ?? false }
    }

    // MARK: Writing

    /// Creates the conversation if it doesn't exist yet. Returns the stored one.
    @discardableResult
    public func create(_ id: ConversationID, title: String?, members: [TransportAddress], pgp: Bool = true, now: Date) throws -> Conversation {
        try db.write { db in
            if try Row.fetchOne(db, sql: "SELECT id FROM conversation WHERE id = ?", arguments: [id.rawValue]) == nil {
                try db.execute(sql: "INSERT INTO conversation (id, title, pgp, lamport, createdAt, lastActivity) VALUES (?, ?, ?, 0, ?, ?)",
                               arguments: [id.rawValue, title, pgp, now, now])
                for member in Set(members) {
                    try db.execute(sql: "INSERT INTO conversationMember (conversationId, address) VALUES (?, ?)",
                                   arguments: [id.rawValue, member.rawValue])
                }
            }
            return try Self.conversation(try Row.fetchOne(db, sql: "SELECT * FROM conversation WHERE id = ?", arguments: [id.rawValue])!, in: db)
        }
    }

    /// Takes the next Lamport counter for a message we're about to send.
    public func nextLamport(in id: ConversationID) throws -> UInt64 {
        try db.write { db in
            let local = try Int64.fetchOne(db, sql: "SELECT lamport FROM conversation WHERE id = ?", arguments: [id.rawValue]) ?? 0
            let next = Lamport.next(after: UInt64(local))
            try db.execute(sql: "UPDATE conversation SET lamport = ? WHERE id = ?", arguments: [Int64(next), id.rawValue])
            return next
        }
    }

    /// Saves a message (sent or received), merges its Lamport counter and applies a PGP setting
    /// change. A message already stored (same ID) is ignored. Returns `false` for a duplicate.
    @discardableResult
    public func insert(_ message: ChatMessage, attachment: Data? = nil, now: Date) throws -> Bool {
        try db.write { db in
            if try Bool.fetchOne(db, sql: "SELECT 1 FROM message WHERE id = ?", arguments: [message.id.uuidString]) == true { return false }
            var attachmentID: String?
            if case .attachment(let info) = message.content, let attachment {
                attachmentID = info.blob.uuidString
                try db.execute(sql: "INSERT OR REPLACE INTO attachment (id, data) VALUES (?, ?)", arguments: [attachmentID, attachment])
            }
            try db.execute(sql: """
                INSERT INTO message (id, conversationId, sender, outgoing, lamport, sentAt, receivedAt, pgp, content, attachmentId)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [message.id.uuidString, message.conversation.rawValue, message.sender.rawValue, message.outgoing,
                                 Int64(message.lamport), message.sentAt, now, message.pgp,
                                 try WireJSON.encoder.encode(message.content), attachmentID])
            let row = try Row.fetchOne(db, sql: "SELECT lamport, pgpLamport FROM conversation WHERE id = ?", arguments: [message.conversation.rawValue])
            let local = UInt64(row?["lamport"] as Int64? ?? 0)
            try db.execute(sql: "UPDATE conversation SET lamport = ?, lastActivity = ? WHERE id = ?",
                           arguments: [Int64(Lamport.merge(local: local, received: message.lamport)), now, message.conversation.rawValue])
            // The latest setting wins, by Lamport counter, so every member ends up with the same one.
            if case .pgpSetting(let on) = message.content, Int64(message.lamport) >= (row?["pgpLamport"] as Int64? ?? 0) {
                try db.execute(sql: "UPDATE conversation SET pgp = ?, pgpLamport = ? WHERE id = ?",
                               arguments: [on, Int64(message.lamport), message.conversation.rawValue])
            }
            return true
        }
    }

    public func delete(_ id: ConversationID) throws {
        try db.write { db in
            try db.execute(sql: """
                DELETE FROM attachment WHERE id IN (SELECT attachmentId FROM message WHERE conversationId = ? AND attachmentId IS NOT NULL)
                """, arguments: [id.rawValue])
            try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [id.rawValue])
        }
    }

    // MARK: Rows

    private static func conversation(_ row: Row, in db: Database) throws -> Conversation {
        let raw: String = row["id"]
        guard let id = ConversationID(rawValue: raw) else { throw DatabaseError(message: "corrupt conversation id \(raw)") }
        let members = try String.fetchAll(db, sql: "SELECT address FROM conversationMember WHERE conversationId = ? ORDER BY address",
                                          arguments: [raw]).compactMap(TransportAddress.init(rawValue:))
        let last = try Row.fetchAll(db, sql: "SELECT * FROM message WHERE conversationId = ? ORDER BY lamport DESC LIMIT 8", arguments: [raw])
            .map(message).max { Lamport.precedes($0.orderKey, $1.orderKey) }
        return Conversation(id: id, title: row["title"], members: members, pgp: row["pgp"],
                            lamport: UInt64(row["lamport"] as Int64), lastActivity: row["lastActivity"], lastMessage: last)
    }

    private static func message(_ row: Row) throws -> ChatMessage {
        let id: String = row["id"], conversation: String = row["conversationId"], sender: String = row["sender"]
        guard let uuid = UUID(uuidString: id), let cid = ConversationID(rawValue: conversation),
              let from = TransportAddress(rawValue: sender) else { throw DatabaseError(message: "corrupt message row \(id)") }
        return ChatMessage(id: uuid, conversation: cid, sender: from, outgoing: row["outgoing"], lamport: UInt64(row["lamport"] as Int64),
                           sentAt: row["sentAt"], pgp: row["pgp"],
                           content: try WireJSON.decoder.decode(MessageContent.self, from: row["content"] as Data))
    }
}

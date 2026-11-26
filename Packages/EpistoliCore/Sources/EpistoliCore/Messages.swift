import Foundation

/// Identifies a conversation on every member's phone. Format: docs/WIRE_FORMAT.md.
///
/// - Direct chats: `d:` + the two members' addresses, sorted, joined by a space. Both phones derive
///   the same ID without agreeing on anything first, so a chat started on either side is one chat.
/// - Groups: `g:` + a random UUID chosen by the creator.
public struct ConversationID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }

    public init?(rawValue: String) {
        guard rawValue.utf8.count <= 2 * ContactCode.maxAddressBytes + 3 else { return nil }
        if rawValue.hasPrefix("g:") {
            guard UUID(uuidString: String(rawValue.dropFirst(2))) != nil else { return nil }
        } else if rawValue.hasPrefix("d:") {
            let parts = rawValue.dropFirst(2).split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] < parts[1],
                  parts.allSatisfy({ TransportAddress(rawValue: String($0)) != nil }) else { return nil }
        } else {
            return nil
        }
        self.rawValue = rawValue
    }

    public static func direct(_ a: TransportAddress, _ b: TransportAddress) -> ConversationID? {
        guard a != b else { return nil }
        let (low, high) = a.rawValue < b.rawValue ? (a, b) : (b, a)
        return ConversationID(rawValue: "d:\(low.rawValue) \(high.rawValue)")
    }

    public static func newGroup() -> ConversationID {
        ConversationID(rawValue: "g:" + UUID().uuidString.lowercased())!
    }

    public var kind: ConversationKind { rawValue.hasPrefix("g:") ? .group : .direct }

    /// The two addresses of a direct chat; empty for a group.
    public var directMembers: [TransportAddress] {
        guard kind == .direct else { return [] }
        return rawValue.dropFirst(2).split(separator: " ").compactMap { TransportAddress(rawValue: String($0)) }
    }
}

/// Lamport clock rules for one conversation (docs/WIRE_FORMAT.md, "Ordering").
public enum Lamport {
    /// The counter for a message we send, given the highest counter this phone has seen in the chat.
    public static func next(after local: UInt64) -> UInt64 { local &+ 1 }

    /// The local counter after receiving a message with `received`.
    public static func merge(local: UInt64, received: UInt64) -> UInt64 { max(local, received) }

    /// Display order: by counter, ties broken by sender address, then message ID. Every phone
    /// sorts the same messages the same way, whatever order they arrived in.
    public static func precedes(_ a: (lamport: UInt64, sender: String, id: UUID),
                                _ b: (lamport: UInt64, sender: String, id: UUID)) -> Bool {
        if a.lamport != b.lamport { return a.lamport < b.lamport }
        if a.sender != b.sender { return a.sender < b.sender }
        return a.id.uuidString < b.id.uuidString
    }
}

/// Where an attachment was picked from, shown under its name ("2.4 MB · from Photos").
public enum AttachmentSource: String, Codable, Sendable, CaseIterable {
    case photos
    case files
    case iCloudDrive

    public var label: String {
        switch self {
        case .photos: "Photos"
        case .files: "Files"
        case .iCloudDrive: "iCloud Drive"
        }
    }
}

public enum AttachmentLimits {
    /// The largest attachment v1 sends or accepts, in bytes.
    public static let maxBytes = 25 * 1024 * 1024
}

/// An attachment as described inside a message. The bytes travel separately as a blob.
public struct AttachmentInfo: Codable, Equatable, Sendable {
    /// Names the blob on the transport (and the attachment on this phone).
    public var blob: UUID
    public var name: String
    /// A MIME type, for example `image/jpeg`.
    public var mime: String
    /// Size of the attachment itself (before encryption), in bytes.
    public var size: Int
    public var source: AttachmentSource
    /// Lowercase hex SHA-256 of the blob exactly as stored on the transport.
    public var blobSHA256: String

    public init(blob: UUID, name: String, mime: String, size: Int, source: AttachmentSource, blobSHA256: String) {
        self.blob = blob
        self.name = name
        self.mime = mime
        self.size = size
        self.source = source
        self.blobSHA256 = blobSHA256
    }

    /// "2.4 MB · from Photos"
    public var detail: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) + " · from " + source.label
    }
}

/// What a message carries.
public enum MessageContent: Equatable, Sendable {
    case text(String)
    case attachment(AttachmentInfo)
    /// Someone turned PGP on or off for the chat. Shown as a line in the chat.
    case pgpSetting(on: Bool)
}

extension MessageContent: Codable {
    private enum CodingKeys: String, CodingKey { case type, text, attachment, on }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "attachment": self = .attachment(try c.decode(AttachmentInfo.self, forKey: .attachment))
        case "pgpSetting": self = .pgpSetting(on: try c.decode(Bool.self, forKey: .on))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown content type \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type); try c.encode(text, forKey: .text)
        case .attachment(let info):
            try c.encode("attachment", forKey: .type); try c.encode(info, forKey: .attachment)
        case .pgpSetting(let on):
            try c.encode("pgpSetting", forKey: .type); try c.encode(on, forKey: .on)
        }
    }
}

/// A group member as introduced by the group's creator.
public struct GroupMember: Codable, Equatable, Sendable {
    public var address: TransportAddress
    public var name: String
    /// Binary OpenPGP public key packets, so members who haven't met can read each other's messages.
    /// A phone that already has this person as a contact ignores it and keeps its own key.
    public var publicKey: Data

    public init(address: TransportAddress, name: String, publicKey: Data) {
        self.address = address
        self.name = name
        self.publicKey = publicKey
    }
}

/// The group's title and members, in every group message. Membership is fixed at creation in v1.
public struct GroupInfo: Codable, Equatable, Sendable {
    public var title: String
    /// Everyone in the group, including the creator.
    public var members: [GroupMember]

    public init(title: String, members: [GroupMember]) {
        self.title = title
        self.members = members
    }
}

/// The signed (and, with PGP on, encrypted) inside of an envelope.
public struct Payload: Codable, Equatable, Sendable {
    public static let version = 1

    public var v: Int
    /// Same as the envelope ID.
    public var id: UUID
    /// The sender. Must match the envelope's `from`.
    public var from: TransportAddress
    public var conversation: ConversationID
    /// Present for groups only.
    public var group: GroupInfo?
    public var lamport: UInt64
    /// The sender's clock, for display only. Ordering uses `lamport`.
    public var sentAt: Date
    public var content: MessageContent

    public init(id: UUID, from: TransportAddress, conversation: ConversationID, group: GroupInfo?,
                lamport: UInt64, sentAt: Date, content: MessageContent) {
        self.v = Self.version
        self.id = id
        self.from = from
        self.conversation = conversation
        self.group = group
        self.lamport = lamport
        self.sentAt = sentAt
        self.content = content
    }

    public func encoded() throws -> Data { try WireJSON.encoder.encode(self) }
    public static func decode(_ data: Data) throws -> Payload { try WireJSON.decoder.decode(Payload.self, from: data) }
}

/// What the transport stores: one file (later one record) per recipient.
public struct Envelope: Codable, Equatable, Sendable {
    public static let version = 1
    /// Envelopes carry text and attachment descriptions only; attachment bytes are separate blobs.
    public static let maxBytes = 1024 * 1024

    public enum Mode: String, Codable, Sendable {
        /// `body` is an OpenPGP message: encrypted to every member and signed by the sender.
        case pgp
        /// PGP off for this chat: `body` is the payload JSON in the clear, `signature` an OpenPGP
        /// detached signature over it. Protected in transit by TLS only; the cloud provider could read it.
        case signed
    }

    public var v: Int
    public var id: UUID
    public var from: TransportAddress
    public var mode: Mode
    public var body: Data
    public var signature: Data?

    public init(id: UUID, from: TransportAddress, mode: Mode, body: Data, signature: Data? = nil) {
        self.v = Self.version
        self.id = id
        self.from = from
        self.mode = mode
        self.body = body
        self.signature = signature
    }

    public func encoded() throws -> Data { try WireJSON.encoder.encode(self) }

    public static func decode(_ data: Data) throws -> Envelope {
        guard data.count <= maxBytes else { throw WireError.tooLarge }
        let envelope = try WireJSON.decoder.decode(Envelope.self, from: data)
        guard envelope.v == version else { throw WireError.unsupportedVersion(envelope.v) }
        guard (envelope.mode == .signed) == (envelope.signature != nil) else { throw WireError.malformed }
        return envelope
    }
}

public enum WireError: Error, Equatable, Sendable {
    case tooLarge
    case unsupportedVersion(Int)
    case malformed
}

/// One JSON style for everything on the wire: sorted keys, dates as seconds since 1970, data as Base64.
public enum WireJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .secondsSince1970
        e.dataEncodingStrategy = .base64
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        d.dataDecodingStrategy = .base64
        return d
    }
}

/// File layout of the loopback transport: a folder shared by simulators on one Mac (section 4).
/// Every path component comes from a validated address or a UUID, never from free text.
public struct LoopbackLayout: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var base: URL { root.appendingPathComponent("v1", isDirectory: true) }
    public var temporary: URL { base.appendingPathComponent("tmp", isDirectory: true) }
    public var blobs: URL { base.appendingPathComponent("blobs", isDirectory: true) }

    /// `nil` unless `address` is a loopback address (`loopback:` + 32 lowercase hex digits).
    public func mailbox(for address: TransportAddress) -> URL? {
        guard Self.isLoopback(address) else { return nil }
        return base.appendingPathComponent("mailboxes", isDirectory: true)
            .appendingPathComponent(String(address.value), isDirectory: true)
    }

    public func rejected(for address: TransportAddress) -> URL? {
        mailbox(for: address)?.appendingPathComponent("rejected", isDirectory: true)
    }

    public func envelopeFile(_ id: UUID, for address: TransportAddress) -> URL? {
        mailbox(for: address)?.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    public func blob(_ id: UUID) -> URL { blobs.appendingPathComponent(id.uuidString.lowercased()) }

    /// The envelope ID from a mailbox file name, or `nil` for anything else in the folder.
    public static func envelopeID(fromFileName name: String) -> UUID? {
        guard name.hasSuffix(".json") else { return nil }
        let stem = String(name.dropLast(5))
        guard stem == stem.lowercased(), let id = UUID(uuidString: stem) else { return nil }
        return id
    }

    public static func isLoopback(_ address: TransportAddress) -> Bool {
        address.scheme == "loopback" && address.value.count == 32
            && address.value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// Tells a member where a conversation lives, so their phone can join it (CloudKit: the share's
/// URL). Sent as a `pgp` envelope to that member only: the transport sees only ciphertext.
public struct Invitation: Codable, Equatable, Sendable {
    public static let version = 1

    public var v: Int
    public var from: TransportAddress
    public var conversation: ConversationID
    /// Transport-specific, for example a CKShare URL.
    public var link: String

    public init(from: TransportAddress, conversation: ConversationID, link: String) {
        self.v = Self.version
        self.from = from
        self.conversation = conversation
        self.link = link
    }

    public func encoded() throws -> Data { try WireJSON.encoder.encode(self) }
    public static func decode(_ data: Data) throws -> Invitation { try WireJSON.decoder.decode(Invitation.self, from: data) }
}

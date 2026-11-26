import Foundation
import EpistoliCore

/// Something waiting to be processed: an envelope, or an invitation to join a conversation.
public struct InboxItem: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case envelope, invitation }

    public let id: UUID
    public let kind: Kind
    /// An `Envelope`, JSON-encoded.
    public let data: Data
    /// Where the item came from, opaque to the messenger. Blobs a message names are fetched from
    /// the same place (CloudKit: the conversation's record zone).
    public let route: String?

    public init(id: UUID, kind: Kind = .envelope, data: Data, route: String? = nil) {
        self.id = id
        self.kind = kind
        self.data = data
        self.route = route
    }
}

/// Moves sealed envelopes and blobs between phones. It never sees plaintext when PGP is on.
/// Section 4: `LoopbackTransport`. Section 5: `CloudKitTransport`.
public protocol Transport: Sendable {
    /// Makes sure every recipient can receive messages in the conversation. CloudKit creates the
    /// conversation's zone and share on first use and leaves each new participant an invitation;
    /// `seal` turns an invitation into a `pgp` envelope for that one recipient.
    func prepare(_ conversation: ConversationID, recipients: [TransportAddress],
                 seal: @Sendable (TransportAddress, Invitation) throws -> Data) async throws
    /// Delivers one envelope (already encrypted to all of `recipients`).
    func deliver(_ envelope: Data, id: UUID, conversation: ConversationID, to recipients: [TransportAddress]) async throws
    /// Stores an attachment blob next to the conversation's messages.
    func putBlob(_ data: Data, id: UUID, conversation: ConversationID) async throws
    /// `nil` if the blob hasn't arrived (yet). `route` is the route of the message that names it.
    func blob(_ id: UUID, route: String?) async throws -> Data?
    /// Fetches anything new and returns everything waiting, oldest first.
    func inbox() async throws -> [InboxItem]
    /// Done with an item: processed, or a duplicate.
    func remove(_ item: InboxItem) async throws
    /// Set aside an item that failed its checks. `retryRejected` puts them back.
    func reject(_ item: InboxItem) async throws
    /// Puts rejected items back, for example after a contact's new key is accepted.
    func retryRejected() async throws
    /// Joins a conversation someone shared with us. Called only after the invitation was decrypted
    /// and its signature verified as coming from a contact.
    func join(_ invitation: Invitation) async throws
}

public enum TransportError: Error, Equatable, Sendable {
    /// The address isn't one this transport can deliver to.
    case unsupportedAddress(String)
    /// The transport's account isn't available (CloudKit: not signed in to iCloud).
    case accountUnavailable
    case invalidLink
}

/// The section 4 transport: a folder on disk. Simulators on one Mac share it, so two simulators can
/// message each other. Layout: `LoopbackLayout` and docs/WIRE_FORMAT.md. Every file is written to a
/// temporary name and then renamed, so a reader never sees half a file.
public struct LoopbackTransport: Transport {
    public let layout: LoopbackLayout
    /// Whose mailbox `inbox()` reads.
    public let owner: TransportAddress

    public init(root: URL, owner: TransportAddress) {
        layout = LoopbackLayout(root: root)
        self.owner = owner
    }

    private var files: FileManager { .default }

    /// Every mailbox is reachable on loopback: nothing to set up.
    public func prepare(_ conversation: ConversationID, recipients: [TransportAddress],
                        seal: @Sendable (TransportAddress, Invitation) throws -> Data) async throws {
        for recipient in recipients where layout.mailbox(for: recipient) == nil {
            throw TransportError.unsupportedAddress(recipient.rawValue)
        }
    }

    public func deliver(_ envelope: Data, id: UUID, conversation: ConversationID, to recipients: [TransportAddress]) async throws {
        for recipient in recipients {
            try deliver(envelope, id: id, to: recipient)
        }
    }

    /// Puts an envelope straight into one mailbox (also used by tests to replay or forge envelopes).
    public func deliver(_ envelope: Data, id: UUID, to recipient: TransportAddress) throws {
        guard let mailbox = layout.mailbox(for: recipient), let file = layout.envelopeFile(id, for: recipient) else {
            throw TransportError.unsupportedAddress(recipient.rawValue)
        }
        try files.createDirectory(at: mailbox, withIntermediateDirectories: true)
        try writeAtomically(envelope, to: file)
    }

    public func putBlob(_ data: Data, id: UUID, conversation: ConversationID) async throws {
        try files.createDirectory(at: layout.blobs, withIntermediateDirectories: true)
        try writeAtomically(data, to: layout.blob(id))
    }

    public func blob(_ id: UUID, route: String?) async throws -> Data? {
        let url = layout.blob(id)
        guard files.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func inbox() async throws -> [InboxItem] {
        guard let mailbox = layout.mailbox(for: owner) else { throw TransportError.unsupportedAddress(owner.rawValue) }
        return try Spool.read(mailbox)
    }

    public func remove(_ item: InboxItem) async throws {
        guard let file = layout.envelopeFile(item.id, for: owner) else { throw TransportError.unsupportedAddress(owner.rawValue) }
        try? files.removeItem(at: file)
    }

    public func reject(_ item: InboxItem) async throws {
        guard let mailbox = layout.mailbox(for: owner) else { throw TransportError.unsupportedAddress(owner.rawValue) }
        try Spool.reject(item.id, in: mailbox)
    }

    public func retryRejected() async throws {
        guard let mailbox = layout.mailbox(for: owner) else { return }
        try Spool.retryRejected(in: mailbox)
    }

    public func join(_ invitation: Invitation) async throws {}

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try Spool.writeAtomically(data, to: url, temporary: layout.temporary)
    }
}

/// A folder of `<uuid>.json` items with a `rejected/` subfolder: the loopback mailbox, and
/// CloudKit's local copy of fetched items that haven't been processed yet.
enum Spool {
    static func read(_ folder: URL, kind: InboxItem.Kind = .envelope, route: String? = nil,
                     maxBytes: Int = Envelope.maxBytes) throws -> [InboxItem] {
        let files = FileManager.default
        guard files.fileExists(atPath: folder.path) else { return [] }
        let urls = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])
        return try urls.compactMap { url -> (Date, String, InboxItem)? in
            guard let id = LoopbackLayout.envelopeID(fromFileName: url.lastPathComponent) else { return nil }
            let values = try url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            // Too large to be an envelope: leave it for `Envelope.decode` to refuse without reading it all.
            let data = (values.fileSize ?? 0) > maxBytes ? Data(count: Envelope.maxBytes + 1) : try Data(contentsOf: url)
            return (values.creationDate ?? .distantPast, url.lastPathComponent, InboxItem(id: id, kind: kind, data: data, route: route))
        }
        .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        .map(\.2)
    }

    static func file(_ id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    static func reject(_ id: UUID, in folder: URL) throws {
        let files = FileManager.default
        let rejected = folder.appendingPathComponent("rejected", isDirectory: true)
        try files.createDirectory(at: rejected, withIntermediateDirectories: true)
        let source = file(id, in: folder), target = file(id, in: rejected)
        guard files.fileExists(atPath: source.path) else { return }
        try? files.removeItem(at: target)
        try files.moveItem(at: source, to: target)
    }

    static func retryRejected(in folder: URL) throws {
        let files = FileManager.default
        let rejected = folder.appendingPathComponent("rejected", isDirectory: true)
        guard files.fileExists(atPath: rejected.path) else { return }
        for url in try files.contentsOfDirectory(at: rejected, includingPropertiesForKeys: nil)
        where LoopbackLayout.envelopeID(fromFileName: url.lastPathComponent) != nil {
            let target = folder.appendingPathComponent(url.lastPathComponent)
            if files.fileExists(atPath: target.path) { try files.removeItem(at: url) } else { try files.moveItem(at: url, to: target) }
        }
    }

    static func writeAtomically(_ data: Data, to url: URL, temporary: URL, protection: Bool = false) throws {
        let files = FileManager.default
        try files.createDirectory(at: temporary, withIntermediateDirectories: true)
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scratch = temporary.appendingPathComponent(UUID().uuidString)
        try data.write(to: scratch, options: protection ? [.completeFileProtection] : [])
        do {
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
            try files.moveItem(at: scratch, to: url)
        } catch {
            try? files.removeItem(at: scratch)
            throw error
        }
    }
}

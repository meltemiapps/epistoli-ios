import CryptoKit
import Foundation
import EpistoliCore

/// The section 5 transport (docs/CLOUDKIT.md).
///
/// - Every conversation lives in one record zone owned by whoever sent its first message, shared
///   with the other members through one CKShare (read-write, participants added by user record ID,
///   no public link access).
/// - Messages are `Envelope` records and attachments `Blob` records in that zone. They hold only
///   what `Messenger` gives them: PGP ciphertext, or signed plaintext when PGP is off for the chat.
/// - A new member learns the share's URL from an `Invite` record in the public database: a `pgp`
///   envelope for them alone, filed under a hash of their address. Nothing else goes public.
/// - Fetches use change tokens. Fetched items are kept in a local spool (complete file protection)
///   until `Messenger` has processed them, so nothing is lost if the app stops halfway.
public actor CloudKitTransport: Transport {
    public static let alertBody = "New message"

    private let db: any CloudDatabase
    private let me: TransportAddress
    private let folder: URL
    private var zones: [String: ZoneState]
    private var seenInvites: Set<String>

    struct ZoneState: Codable {
        var zone: ZoneRef
        /// For our own zones: the users the share includes.
        var participants: Set<String>
    }

    /// - Parameters:
    ///   - me: our `icloud:` address (`address(forUser:)` of `db.currentUser()`).
    ///   - folder: local state (spool, change token, zone map), in Application Support.
    public init(database: any CloudDatabase, me: TransportAddress, folder: URL) throws {
        self.db = database
        self.me = me
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        zones = (try? JSONDecoder().decode([String: ZoneState].self, from: Data(contentsOf: folder.appendingPathComponent("zones.json")))) ?? [:]
        seenInvites = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: folder.appendingPathComponent("invites.json")))) ?? []
    }

    // MARK: Addresses and names

    public static func address(forUser recordName: String) -> TransportAddress? {
        guard isValidUser(recordName) else { return nil }
        return TransportAddress(scheme: "icloud", value: recordName)
    }

    static func user(of address: TransportAddress) -> String? {
        guard address.scheme == "icloud", isValidUser(String(address.value)) else { return nil }
        return String(address.value)
    }

    static func isValidUser(_ name: String) -> Bool {
        (1...100).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// The zone of a conversation: a hash, so zone names don't reveal who is talking to whom.
    public static func zoneName(for conversation: ConversationID) -> String {
        "c-" + hex(SHA256.hash(data: Data(conversation.rawValue.utf8))).prefix(32)
    }

    /// Where invitations for `address` are filed in the public database: a hash, not the address.
    public static func inviteKey(for address: TransportAddress) -> String {
        hex(SHA256.hash(data: Data(("invite-v1|" + address.rawValue).utf8)))
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    // MARK: Transport

    public func prepare(_ conversation: ConversationID, recipients: [TransportAddress],
                        seal: @Sendable (TransportAddress, Invitation) throws -> Data) async throws {
        let users = try recipients.map { address -> String in
            guard let user = Self.user(of: address) else { throw TransportError.unsupportedAddress(address.rawValue) }
            return user
        }
        var state = zones[conversation.rawValue]
        // A conversation someone else shared with us: they manage the share.
        if let state, !state.zone.isOurs { return }
        let missing = Set(users).subtracting(state?.participants ?? [])
        guard state == nil || !missing.isEmpty else { return }

        let name = Self.zoneName(for: conversation)
        if state == nil { try await db.createZone(name) }
        let url = try await db.share(zone: name, with: users)
        for recipient in recipients where missing.contains(Self.user(of: recipient) ?? "") {
            let sealed = try seal(recipient, Invitation(from: me, conversation: conversation, link: url.absoluteString))
            try await db.savePublic(CloudRecord(type: "Invite", name: UUID().uuidString.lowercased(),
                                                strings: ["recipient": Self.inviteKey(for: recipient)],
                                                bytes: ["envelope": sealed]))
        }
        state = ZoneState(zone: ZoneRef(name: name, owner: nil), participants: Set(users).union(state?.participants ?? []))
        zones[conversation.rawValue] = state
        try saveZones()
    }

    public func deliver(_ envelope: Data, id: UUID, conversation: ConversationID, to recipients: [TransportAddress]) async throws {
        guard let zone = zones[conversation.rawValue]?.zone else { throw TransportError.unsupportedAddress(conversation.rawValue) }
        // Envelopes are at most 1 MiB; CloudKit records at most 1 MB, so large ones go in an asset.
        let small = envelope.count <= 700_000
        try await db.save(CloudRecord(type: "Envelope", name: id.uuidString.lowercased(), strings: ["sender": me.rawValue],
                                      bytes: small ? ["envelope": envelope] : [:], assets: small ? [:] : ["envelopeFile": envelope]),
                          in: zone)
    }

    public func putBlob(_ data: Data, id: UUID, conversation: ConversationID) async throws {
        guard let zone = zones[conversation.rawValue]?.zone else { throw TransportError.unsupportedAddress(conversation.rawValue) }
        try await db.save(CloudRecord(type: "Blob", name: "blob-" + id.uuidString.lowercased(), assets: ["data": data]), in: zone)
    }

    public func blob(_ id: UUID, route: String?) async throws -> Data? {
        guard let route, let zone = try? JSONDecoder().decode(ZoneRef.self, from: Data(route.utf8)) else { return nil }
        return try await db.record(named: "blob-" + id.uuidString.lowercased(), in: zone)?.assets["data"]
    }

    public func inbox() async throws -> [InboxItem] {
        try await fetch()
        return try spooled()
    }

    public func remove(_ item: InboxItem) async throws {
        try? FileManager.default.removeItem(at: Spool.file(item.id, in: spool))
    }

    public func reject(_ item: InboxItem) async throws {
        try Spool.reject(item.id, in: spool)
    }

    public func retryRejected() async throws {
        try Spool.retryRejected(in: spool)
    }

    public func join(_ invitation: Invitation) async throws {
        guard let url = URL(string: invitation.link), url.scheme == "https",
              let host = url.host(), host == "icloud.com" || host.hasSuffix(".icloud.com") else { throw TransportError.invalidLink }
        let zone = try await db.acceptShare(url)
        // If we already have a zone for this chat (both sides started it at once), keep writing
        // there; we read both.
        if zones[invitation.conversation.rawValue] == nil {
            zones[invitation.conversation.rawValue] = ZoneState(zone: zone, participants: [])
            try saveZones()
        }
    }

    /// Asks CloudKit for "New message" pushes. They are only a hint to fetch: the app also fetches
    /// on launch, in background refresh and on pull-to-refresh.
    public func subscribeToAlerts() async throws {
        try await db.subscribe(alertBody: Self.alertBody)
    }

    // MARK: Fetching

    private var spool: URL { folder.appendingPathComponent("inbox", isDirectory: true) }
    private var temporary: URL { folder.appendingPathComponent("tmp", isDirectory: true) }

    private struct SpoolEntry: Codable {
        var kind: InboxItem.Kind
        var route: String?
        var data: Data
    }

    private func fetch() async throws {
        // Messages: every zone we own or joined. The token is saved only after the items are spooled.
        let tokenURL = folder.appendingPathComponent("changes.token")
        let changes = try await db.changes(since: try? Data(contentsOf: tokenURL))
        for (zone, record) in changes.records where record.type == "Envelope" && record.strings["sender"] != me.rawValue {
            guard let id = UUID(uuidString: record.name),
                  let data = record.bytes["envelope"] ?? record.assets["envelopeFile"] else { continue }
            let route = String(decoding: try JSONEncoder().encode(zone), as: UTF8.self)
            try spool(SpoolEntry(kind: .envelope, route: route, data: data), id: id)
        }
        try Spool.writeAtomically(changes.state, to: tokenURL, temporary: temporary, protection: true)

        // Invitations for us in the public database.
        let invites = try await db.queryPublic(type: "Invite", field: "recipient", equals: Self.inviteKey(for: me))
        var changed = false
        for invite in invites where !seenInvites.contains(invite.name) {
            seenInvites.insert(invite.name)
            changed = true
            guard let id = UUID(uuidString: invite.name), let data = invite.bytes["envelope"] else { continue }
            try spool(SpoolEntry(kind: .invitation, route: nil, data: data), id: id)
        }
        if changed {
            try Spool.writeAtomically(try JSONEncoder().encode(seenInvites), to: folder.appendingPathComponent("invites.json"),
                                      temporary: temporary, protection: true)
        }
    }

    private func spool(_ entry: SpoolEntry, id: UUID) throws {
        let file = Spool.file(id, in: spool)
        let rejected = Spool.file(id, in: spool.appendingPathComponent("rejected", isDirectory: true))
        guard !FileManager.default.fileExists(atPath: rejected.path) else { return }
        try Spool.writeAtomically(try JSONEncoder().encode(entry), to: file, temporary: temporary, protection: true)
    }

    private func spooled() throws -> [InboxItem] {
        // Entries hold the envelope as Base64 inside JSON, so they may be up to 4/3 larger.
        try Spool.read(spool, maxBytes: 2 * Envelope.maxBytes).map { raw in
            // A damaged entry is handed on as an empty envelope, which the messenger rejects.
            guard let entry = try? JSONDecoder().decode(SpoolEntry.self, from: raw.data) else { return InboxItem(id: raw.id, data: Data()) }
            return InboxItem(id: raw.id, kind: entry.kind, data: entry.data, route: entry.route)
        }
    }

    private func saveZones() throws {
        try Spool.writeAtomically(try JSONEncoder().encode(zones), to: folder.appendingPathComponent("zones.json"),
                                  temporary: temporary, protection: true)
    }
}

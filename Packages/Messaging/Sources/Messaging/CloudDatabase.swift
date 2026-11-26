import Foundation

/// A record zone as this phone sees it.
public struct ZoneRef: Codable, Hashable, Sendable {
    public var name: String
    /// The owner's user record name, or `nil` for our own zone (private database).
    /// Zones owned by someone else are reached through the shared database.
    public var owner: String?

    public init(name: String, owner: String?) {
        self.name = name
        self.owner = owner
    }

    public var isOurs: Bool { owner == nil }
}

/// The few CloudKit record shapes the transport uses (docs/CLOUDKIT.md, "Record types").
public struct CloudRecord: Sendable, Equatable {
    public var type: String
    public var name: String
    public var strings: [String: String]
    /// Small binary fields (CloudKit `Bytes`).
    public var bytes: [String: Data]
    /// Large binary fields (CloudKit `Asset`).
    public var assets: [String: Data]

    public init(type: String, name: String, strings: [String: String] = [:], bytes: [String: Data] = [:], assets: [String: Data] = [:]) {
        self.type = type
        self.name = name
        self.strings = strings
        self.bytes = bytes
        self.assets = assets
    }
}

/// What changed since the last fetch, in every zone we own or joined.
public struct CloudChanges: Sendable {
    public var records: [(zone: ZoneRef, record: CloudRecord)]
    /// Opaque; pass it to the next `changes(since:)`.
    public var state: Data

    public init(records: [(zone: ZoneRef, record: CloudRecord)], state: Data) {
        self.records = records
        self.state = state
    }
}

/// The CloudKit operations the transport needs. `CloudKitDatabase` is the real one; tests use an
/// in-memory iCloud with several users (MessagingTests/MockCloud.swift).
public protocol CloudDatabase: Sendable {
    /// Our user record name (`_` followed by hex). Throws `TransportError.accountUnavailable` when
    /// the device isn't signed in to iCloud.
    func currentUser() async throws -> String
    /// Creates a zone in our private database (no-op if it exists).
    func createZone(_ name: String) async throws
    /// Shares our zone with these users only (read-write, no public access), adding any who aren't
    /// participants yet. Returns the share's URL.
    func share(zone name: String, with users: [String]) async throws -> URL
    func save(_ record: CloudRecord, in zone: ZoneRef) async throws
    func record(named name: String, in zone: ZoneRef) async throws -> CloudRecord?
    /// Changes in our zones (private database) and joined zones (shared database) since `state`.
    func changes(since state: Data?) async throws -> CloudChanges
    func savePublic(_ record: CloudRecord) async throws
    func queryPublic(type: String, field: String, equals value: String) async throws -> [CloudRecord]
    /// Accepts a share we're a participant of. Returns the shared zone.
    func acceptShare(_ url: URL) async throws -> ZoneRef
    /// Push notifications for changes in the private and shared databases, with this fixed alert
    /// text. CloudKit sends the alert; the app never puts message content in it.
    func subscribe(alertBody: String) async throws
}

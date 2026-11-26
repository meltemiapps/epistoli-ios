import Foundation
@testable import Messaging

/// An in-memory iCloud with several users, enforcing the rules the transport relies on:
/// - a zone is readable and writable only by its owner and by participants who accepted its share;
/// - only participants the owner added can accept a share (no public link access);
/// - the public database is readable by everyone.
actor MockCloud {
    struct Zone {
        var participants: Set<String> = []
        var accepted: Set<String> = []
        var records: [String: CloudRecord] = [:]
        var url: URL?
    }

    private(set) var zones: [String: [String: Zone]] = [:]          // owner → name → zone
    private(set) var publicRecords: [CloudRecord] = []
    private(set) var log: [(seq: Int, owner: String, zone: String, record: String)] = []
    private(set) var subscriptions: [String: String] = [:]           // user → alert body
    private var seq = 0

    enum Failure: Error, Equatable { case notPermitted, noSuchZone, noSuchShare }

    func createZone(_ name: String, owner: String) {
        if zones[owner]?[name] == nil { zones[owner, default: [:]][name] = Zone() }
    }

    func share(_ name: String, owner: String, with users: [String]) throws -> URL {
        guard var zone = zones[owner]?[name] else { throw Failure.noSuchZone }
        zone.participants.formUnion(users)
        let url = zone.url ?? URL(string: "https://www.icloud.com/share/\(UUID().uuidString.lowercased())")!
        zone.url = url
        zones[owner]?[name] = zone
        return url
    }

    private func owner(of zone: ZoneRef, user: String) -> String { zone.owner ?? user }

    private func check(_ zone: ZoneRef, user: String) throws -> (owner: String, zone: Zone) {
        let owner = owner(of: zone, user: user)
        guard let z = zones[owner]?[zone.name] else { throw Failure.noSuchZone }
        guard owner == user || z.accepted.contains(user) else { throw Failure.notPermitted }
        return (owner, z)
    }

    func save(_ record: CloudRecord, in zone: ZoneRef, user: String) throws {
        let (owner, _) = try check(zone, user: user)
        zones[owner]?[zone.name]?.records[record.name] = record
        seq += 1
        log.append((seq, owner, zone.name, record.name))
    }

    func record(_ name: String, in zone: ZoneRef, user: String) throws -> CloudRecord? {
        try check(zone, user: user).zone.records[name]
    }

    func changes(user: String, since: Int) -> ([(ZoneRef, CloudRecord)], Int) {
        let visible = log.filter { $0.seq > since }.compactMap { entry -> (ZoneRef, CloudRecord)? in
            guard let zone = zones[entry.owner]?[entry.zone], entry.owner == user || zone.accepted.contains(user),
                  let record = zone.records[entry.record] else { return nil }
            return (ZoneRef(name: entry.zone, owner: entry.owner == user ? nil : entry.owner), record)
        }
        return (visible, seq)
    }

    func savePublic(_ record: CloudRecord) { publicRecords.append(record) }

    func queryPublic(type: String, field: String, value: String) -> [CloudRecord] {
        publicRecords.filter { $0.type == type && $0.strings[field] == value }
    }

    func accept(_ url: URL, user: String) throws -> ZoneRef {
        for (owner, ownerZones) in zones {
            for (name, zone) in ownerZones where zone.url == url {
                guard zone.participants.contains(user) else { throw Failure.notPermitted }
                zones[owner]?[name]?.accepted.insert(user)
                // Accepting makes the zone's existing records visible to the next fetch.
                for record in zone.records.keys {
                    seq += 1
                    log.append((seq, owner, name, record))
                }
                return ZoneRef(name: name, owner: owner)
            }
        }
        throw Failure.noSuchShare
    }

    func subscribe(user: String, alertBody: String) { subscriptions[user] = alertBody }

    /// Every byte stored anywhere, for checking what Apple could see.
    func allStoredData() -> [Data] {
        let zoneData = zones.values.flatMap(\.values).flatMap(\.records.values).flatMap { r in
            Array(r.bytes.values) + Array(r.assets.values) + r.strings.values.map { Data($0.utf8) }
        }
        let publicData = publicRecords.flatMap { r in Array(r.bytes.values) + r.strings.values.map { Data($0.utf8) } }
        return zoneData + publicData
    }
}

/// One user's view of `MockCloud`.
struct MockCloudDatabase: CloudDatabase {
    let cloud: MockCloud
    let user: String

    func currentUser() async throws -> String { user }
    func createZone(_ name: String) async throws { await cloud.createZone(name, owner: user) }
    func share(zone name: String, with users: [String]) async throws -> URL { try await cloud.share(name, owner: user, with: users) }
    func save(_ record: CloudRecord, in zone: ZoneRef) async throws { try await cloud.save(record, in: zone, user: user) }
    func record(named name: String, in zone: ZoneRef) async throws -> CloudRecord? { try await cloud.record(name, in: zone, user: user) }

    func changes(since state: Data?) async throws -> CloudChanges {
        let since = state.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let (records, next) = await cloud.changes(user: user, since: since)
        return CloudChanges(records: records.map { (zone: $0.0, record: $0.1) }, state: Data(String(next).utf8))
    }

    func savePublic(_ record: CloudRecord) async throws { await cloud.savePublic(record) }
    func queryPublic(type: String, field: String, equals value: String) async throws -> [CloudRecord] {
        await cloud.queryPublic(type: type, field: field, value: value)
    }
    func acceptShare(_ url: URL) async throws -> ZoneRef { try await cloud.accept(url, user: user) }
    func subscribe(alertBody: String) async throws { await cloud.subscribe(user: user, alertBody: alertBody) }
}

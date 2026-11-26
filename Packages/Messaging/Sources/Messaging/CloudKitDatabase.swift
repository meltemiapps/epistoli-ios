import CloudKit
import Foundation

/// `CloudDatabase` on a real CKContainer. Needs the iCloud (CloudKit) entitlement for the
/// container, which only a signed build has (docs/CLOUDKIT.md, "Turning it on"). Unit tests use
/// the in-memory mock instead; this type is exercised by the device test plan.
public struct CloudKitDatabase: CloudDatabase {
    private let container: CKContainer

    public init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    private var privateDB: CKDatabase { container.privateCloudDatabase }
    private var sharedDB: CKDatabase { container.sharedCloudDatabase }

    private func database(for zone: ZoneRef) -> CKDatabase { zone.isOurs ? privateDB : sharedDB }

    private func zoneID(_ zone: ZoneRef) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone.name, ownerName: zone.owner ?? CKCurrentUserDefaultName)
    }

    public func currentUser() async throws -> String {
        guard try await container.accountStatus() == .available else { throw TransportError.accountUnavailable }
        return try await container.userRecordID().recordName
    }

    public func createZone(_ name: String) async throws {
        let zone = CKRecordZone(zoneName: name)
        let result = try await privateDB.modifyRecordZones(saving: [zone], deleting: [])
        _ = try result.saveResults[zone.zoneID]?.get()
    }

    public func share(zone name: String, with users: [String]) async throws -> URL {
        let id = CKRecordZone.ID(zoneName: name, ownerName: CKCurrentUserDefaultName)
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: id)
        let share: CKShare
        if let existing = try await optionalRecord(shareID, in: privateDB) as? CKShare {
            share = existing
        } else {
            share = CKShare(recordZoneID: id)
            share.publicPermission = .none   // only the participants added below, never "anyone with the link"
        }
        let present = Set(share.participants.compactMap { $0.userIdentity.userRecordID?.recordName })
        let missing = users.filter { !present.contains($0) }.map { CKRecord.ID(recordName: $0) }
        if !missing.isEmpty {
            for (_, result) in try await container.shareParticipants(forUserRecordIDs: missing) {
                let participant = try result.get()
                participant.permission = .readWrite
                share.addParticipant(participant)
            }
        }
        let saved = try await privateDB.modifyRecords(saving: [share], deleting: [], savePolicy: .changedKeys)
        let url = (try saved.saveResults[share.recordID]?.get() as? CKShare)?.url ?? share.url
        guard let url else { throw TransportError.invalidLink }
        return url
    }

    public func save(_ record: CloudRecord, in zone: ZoneRef) async throws {
        try await save(record, id: CKRecord.ID(recordName: record.name, zoneID: zoneID(zone)), in: database(for: zone))
    }

    public func record(named name: String, in zone: ZoneRef) async throws -> CloudRecord? {
        try await optionalRecord(CKRecord.ID(recordName: name, zoneID: zoneID(zone)), in: database(for: zone)).map(Self.cloudRecord)
    }

    public func changes(since state: Data?) async throws -> CloudChanges {
        var tokens = (state.flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }) ?? Tokens()
        var records: [(zone: ZoneRef, record: CloudRecord)] = []
        for (scope, db) in [("private", privateDB), ("shared", sharedDB)] {
            var zones: Set<CKRecordZone.ID> = []
            var token = tokens.database[scope].flatMap(Self.unarchive)
            var more = true
            while more {
                let result: (modifications: [CKDatabase.DatabaseChange.Modification], deletions: [CKDatabase.DatabaseChange.Deletion],
                             changeToken: CKServerChangeToken, moreComing: Bool)
                do {
                    result = try await db.databaseChanges(since: token)
                } catch let error as CKError where error.code == .changeTokenExpired {
                    token = nil
                    continue
                }
                zones.formUnion(result.modifications.map(\.zoneID))
                for deletion in result.deletions { tokens.zone[Self.key(deletion.zoneID)] = nil }
                token = result.changeToken
                more = result.moreComing
            }
            tokens.database[scope] = token.flatMap(Self.archive)

            for id in zones where id.zoneName != CKRecordZone.ID.defaultZoneName {
                let ref = ZoneRef(name: id.zoneName, owner: scope == "private" ? nil : id.ownerName)
                var zoneToken = tokens.zone[Self.key(id)].flatMap(Self.unarchive)
                var moreInZone = true
                while moreInZone {
                    let result: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                                 deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
                    do {
                        result = try await db.recordZoneChanges(inZoneWith: id, since: zoneToken)
                    } catch let error as CKError where error.code == .changeTokenExpired {
                        zoneToken = nil
                        continue
                    }
                    for case .success(let modification) in result.modificationResultsByID.values {
                        records.append((ref, Self.cloudRecord(modification.record)))
                    }
                    zoneToken = result.changeToken
                    moreInZone = result.moreComing
                }
                tokens.zone[Self.key(id)] = zoneToken.flatMap(Self.archive)
            }
        }
        return CloudChanges(records: records, state: try JSONEncoder().encode(tokens))
    }

    public func savePublic(_ record: CloudRecord) async throws {
        try await save(record, id: CKRecord.ID(recordName: record.name), in: container.publicCloudDatabase)
    }

    public func queryPublic(type: String, field: String, equals value: String) async throws -> [CloudRecord] {
        let query = CKQuery(recordType: type, predicate: NSPredicate(format: "%K == %@", field, value))
        var page = try await container.publicCloudDatabase.records(matching: query)
        var records = page.matchResults.compactMap { try? $0.1.get() }
        while let cursor = page.queryCursor {
            page = try await container.publicCloudDatabase.records(continuingMatchFrom: cursor)
            records += page.matchResults.compactMap { try? $0.1.get() }
        }
        return records.map(Self.cloudRecord)
    }

    public func acceptShare(_ url: URL) async throws -> ZoneRef {
        let metadata = try await container.shareMetadata(for: url)
        _ = try await container.accept(metadata)
        let zone = metadata.share.recordID.zoneID
        return ZoneRef(name: zone.zoneName, owner: zone.ownerName)
    }

    public func subscribe(alertBody: String) async throws {
        for db in [privateDB, sharedDB] {
            let subscription = CKDatabaseSubscription(subscriptionID: "changes")
            let info = CKSubscription.NotificationInfo()
            info.alertBody = alertBody          // fixed text: never the sender, chat or message
            info.soundName = "default"
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            let result = try await db.modifySubscriptions(saving: [subscription], deleting: [])
            _ = try result.saveResults[subscription.subscriptionID]?.get()
        }
    }

    // MARK: Helpers

    private struct Tokens: Codable {
        var database: [String: Data] = [:]
        var zone: [String: Data] = [:]
    }

    private static func key(_ id: CKRecordZone.ID) -> String { id.ownerName + "/" + id.zoneName }

    private static func archive(_ token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func unarchive(_ data: Data) -> CKServerChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func optionalRecord(_ id: CKRecord.ID, in db: CKDatabase) async throws -> CKRecord? {
        do {
            return try await db.record(for: id)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    private func save(_ record: CloudRecord, id: CKRecord.ID, in db: CKDatabase) async throws {
        let ck = CKRecord(recordType: record.type, recordID: id)
        for (key, value) in record.strings { ck[key] = value as NSString }
        for (key, value) in record.bytes { ck[key] = value as NSData }
        var temporary: [URL] = []
        defer { temporary.forEach { try? FileManager.default.removeItem(at: $0) } }
        for (key, value) in record.assets {
            // CKAsset uploads from a file. It holds ciphertext when PGP is on, and is deleted after.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
            try value.write(to: url, options: [.completeFileProtection])
            temporary.append(url)
            ck[key] = CKAsset(fileURL: url)
        }
        let result = try await db.modifyRecords(saving: [ck], deleting: [], savePolicy: .allKeys)
        _ = try result.saveResults[id]?.get()
    }

    private static func cloudRecord(_ ck: CKRecord) -> CloudRecord {
        var record = CloudRecord(type: ck.recordType, name: ck.recordID.recordName)
        for key in ck.allKeys() {
            switch ck[key] {
            case let value as String: record.strings[key] = value
            case let value as Data: record.bytes[key] = value
            case let asset as CKAsset: record.assets[key] = asset.fileURL.flatMap { try? Data(contentsOf: $0) }
            default: break
            }
        }
        return record
    }
}

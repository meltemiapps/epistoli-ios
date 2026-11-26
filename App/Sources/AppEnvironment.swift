import Foundation
import EpistoliCore
import GRDB
import KeyExchange
import Messaging
import SealedStorage

/// The app's stores, wired to the real Keychain, Secure Enclave and SQLCipher database.
///
/// One Secure Enclave P-256 key (a software key on the simulator) wraps both the database key and
/// the identity private key. Both wrapped secrets are Keychain items, `WhenUnlockedThisDeviceOnly`.
struct AppEnvironment: Sendable {
    let identities: IdentityStore
    let contacts: ContactStore
    let conversations: ConversationStore
    let transportKind: TransportKind
    /// The loopback folder (section 4).
    let loopbackRoot: URL
    /// CloudKit (section 5): the container and the transport's local state folder.
    let cloud: (any CloudDatabase)?
    let cloudState: URL
    let database: any DatabaseWriter
    let secrets: KeychainStore
    let wrapperTag: String

    /// The real configuration. The Keychain service and key tag derive from the bundle identifier,
    /// so no brand string is hard-coded here.
    static func live() throws -> AppEnvironment {
        let service = Bundle.main.bundleIdentifier ?? "app"
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let kind = TransportKind(rawValue: Bundle.main.object(forInfoDictionaryKey: "TransportKind") as? String ?? "") ?? .loopback
        let container = Bundle.main.object(forInfoDictionaryKey: "CloudKitContainer") as? String ?? ""
        return try make(service: service, wrapperTag: service + ".wrapping-key",
                        databaseURL: support.appendingPathComponent("store.sqlite"),
                        loopbackRoot: loopbackRoot(default: support.appendingPathComponent("Loopback", isDirectory: true)),
                        transportKind: kind,
                        cloud: kind == .cloudkit && !container.isEmpty ? CloudKitDatabase(containerIdentifier: container) : nil,
                        cloudState: support.appendingPathComponent("CloudKit", isDirectory: true))
    }

    /// The loopback transport's shared folder (section 4). Simulators on one Mac pass the same
    /// folder with the launch argument `-loopback.root <path>`; otherwise messages stay on this phone.
    static func loopbackRoot(default fallback: URL) -> URL {
        if let path = UserDefaults.standard.string(forKey: "loopback.root"), path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return fallback
    }

    static func make(service: String, wrapperTag: String, databaseURL: URL, loopbackRoot: URL,
                     transportKind: TransportKind = .loopback, cloud: (any CloudDatabase)? = nil,
                     cloudState: URL? = nil) throws -> AppEnvironment {
        let secrets = KeychainStore(service: service)
        let wrapper = try SecureEnclaveKeyWrapper(tag: wrapperTag)
        let key = try DatabaseKeyProvider(store: secrets, wrapper: wrapper).key()
        let database = try SealedDatabase.open(at: databaseURL, key: key, migrator: migrator)
        return AppEnvironment(identities: IdentityStore(store: secrets, wrapper: wrapper),
                              contacts: ContactStore(db: database), conversations: ConversationStore(db: database),
                              transportKind: transportKind, loopbackRoot: loopbackRoot, cloud: cloud,
                              cloudState: cloudState ?? databaseURL.deletingLastPathComponent().appendingPathComponent("CloudKit"),
                              database: database,
                              secrets: secrets, wrapperTag: wrapperTag)
    }

    /// The transport for our identity's address.
    func transport(for address: TransportAddress) throws -> any Transport {
        switch transportKind {
        case .loopback:
            return LoopbackTransport(root: loopbackRoot, owner: address)
        case .cloudkit:
            guard let cloud else { throw TransportError.accountUnavailable }
            return try CloudKitTransport(database: cloud, me: address, folder: cloudState)
        }
    }

    /// The address for a new identity: a random loopback mailbox, or our iCloud user.
    func newAddress() async throws -> TransportAddress? {
        switch transportKind {
        case .loopback:
            return nil   // IdentityStore makes one
        case .cloudkit:
            guard let cloud, let address = CloudKitTransport.address(forUser: try await cloud.currentUser()) else {
                throw TransportError.accountUnavailable
            }
            return address
        }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        ContactStore.registerMigrations(in: &migrator)
        ConversationStore.registerMigrations(in: &migrator)
        return migrator
    }
}

enum TransportKind: String, Sendable {
    case loopback
    case cloudkit

    /// CloudKit sends "New message" pushes; the loopback folder can't.
    var hasPushAlerts: Bool { self == .cloudkit }
}

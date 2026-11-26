import Foundation
import GRDB
import KeyExchange
import SealedStorage

/// The app's stores, wired to the real Keychain, Secure Enclave and SQLCipher database.
///
/// One Secure Enclave P-256 key (a software key on the simulator) wraps both the database key and
/// the identity private key. Both wrapped secrets are Keychain items, `WhenUnlockedThisDeviceOnly`.
struct AppEnvironment: Sendable {
    let identities: IdentityStore
    let contacts: ContactStore
    let database: any DatabaseWriter
    let secrets: KeychainStore
    let wrapperTag: String

    /// The real configuration. The Keychain service and key tag derive from the bundle identifier,
    /// so no brand string is hard-coded here.
    static func live() throws -> AppEnvironment {
        let service = Bundle.main.bundleIdentifier ?? "app"
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return try make(service: service, wrapperTag: service + ".wrapping-key",
                        databaseURL: support.appendingPathComponent("store.sqlite"))
    }

    static func make(service: String, wrapperTag: String, databaseURL: URL) throws -> AppEnvironment {
        let secrets = KeychainStore(service: service)
        let wrapper = try SecureEnclaveKeyWrapper(tag: wrapperTag)
        let key = try DatabaseKeyProvider(store: secrets, wrapper: wrapper).key()
        let database = try SealedDatabase.open(at: databaseURL, key: key, migrator: migrator)
        return AppEnvironment(identities: IdentityStore(store: secrets, wrapper: wrapper),
                              contacts: ContactStore(db: database), database: database,
                              secrets: secrets, wrapperTag: wrapperTag)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        ContactStore.registerMigrations(in: &migrator)
        return migrator
    }
}

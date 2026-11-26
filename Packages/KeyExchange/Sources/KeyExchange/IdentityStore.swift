import Foundation
import OSLog
import Security
import EpistoliCore
import SealedCrypto
import SealedStorage

/// Our own identity: the OpenPGP key pair plus what we show in "My code".
public struct Identity: Sendable {
    public let displayName: String
    public let address: TransportAddress
    public let privateKey: PGPPrivateKey
    public let publicKey: PGPPublicKey

    public var fingerprint: Fingerprint { publicKey.fingerprint }
}

public enum IdentityError: Error, Equatable, Sendable {
    case emptyName
    case corruptProfile
}

/// Keeps the identity private key exactly like the database key: in the Keychain
/// (`WhenUnlockedThisDeviceOnly`, never synced), wrapped by the Secure Enclave P-256 key
/// (a software key on the simulator). The private key is never written to the database,
/// to files, to logs or into any export; "My code" carries only the public key.
///
/// v1 keys are device-only: there is no backup yet (see docs/ROADMAP.md).
public struct IdentityStore: Sendable {
    /// Keychain account holding the wrapped private key.
    public static let keyAccount = "identity-key.wrapped"
    /// Keychain account holding the display name and address (not secret; kept next to the key
    /// so the pair survives together).
    public static let profileAccount = "identity-profile"

    /// The OpenPGP user ID of every identity key. The person's name is carried in the contact code
    /// and the profile instead, so the key reveals no name, renaming never needs a new key, and the
    /// QR code stays small (a Greek name would otherwise be stored twice, at 2 bytes per letter).
    public static let keyUserID = "-"

    private static let log = Logger(subsystem: "KeyExchange", category: "identity")

    private let store: any SecretStore
    private let wrapper: any KeyWrapper

    public init(store: any SecretStore, wrapper: any KeyWrapper) {
        self.store = store
        self.wrapper = wrapper
    }

    private struct Profile: Codable {
        var displayName: String
        var address: String
    }

    /// The stored identity, or `nil` before onboarding.
    public func load() throws -> Identity? {
        guard let wrapped = try store.data(for: Self.keyAccount),
              let profileData = try store.data(for: Self.profileAccount) else { return nil }
        let privateKey = PGPPrivateKey(data: try wrapper.unwrap(wrapped))
        guard let profile = try? JSONDecoder().decode(Profile.self, from: profileData),
              let address = TransportAddress(rawValue: profile.address) else { throw IdentityError.corruptProfile }
        return Identity(displayName: profile.displayName, address: address,
                        privateKey: privateKey, publicKey: try SealedCrypto.publicKey(of: privateKey))
    }

    /// Creates a new key pair and a new address. Replaces any existing identity.
    public func create(displayName: String) throws -> Identity {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw IdentityError.emptyName }
        return try save(name: name, address: try Self.newLoopbackAddress(), privateKey: SealedCrypto.generateIdentity(name: Self.keyUserID))
    }

    /// A new key pair for the same name and address: what a contact sees when someone gets a new
    /// phone. Used by the Debug-only "Simulate new phone" setting to test the key-change warning.
    public func replaceKey(of identity: Identity) throws -> Identity {
        try save(name: identity.displayName, address: identity.address,
                 privateKey: SealedCrypto.generateIdentity(name: Self.keyUserID))
    }

    /// Changes the name shown in "My code". The key stays the same.
    public func rename(_ identity: Identity, to displayName: String) throws -> Identity {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw IdentityError.emptyName }
        try store.set(try JSONEncoder().encode(Profile(displayName: name, address: identity.address.rawValue)), for: Self.profileAccount)
        return Identity(displayName: name, address: identity.address, privateKey: identity.privateKey, publicKey: identity.publicKey)
    }

    private func save(name: String, address: TransportAddress, privateKey: PGPPrivateKey) throws -> Identity {
        let publicKey = try SealedCrypto.publicKey(of: privateKey)
        try store.set(try wrapper.wrap(privateKey.data), for: Self.keyAccount)
        try store.set(try JSONEncoder().encode(Profile(displayName: name, address: address.rawValue)), for: Self.profileAccount)
        // Only public information is ever logged.
        Self.log.info("Stored identity key \(publicKey.fingerprint.hex, privacy: .public)")
        return Identity(displayName: name, address: address, privateKey: privateKey, publicKey: publicKey)
    }

    /// A random mailbox on the loopback transport (section 4). Section 5 adds iCloud addresses.
    static func newLoopbackAddress() throws -> TransportAddress {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw SealedStorageError.randomFailed(status) }
        return TransportAddress(scheme: "loopback", value: bytes.map { String(format: "%02x", $0) }.joined())!
    }
}

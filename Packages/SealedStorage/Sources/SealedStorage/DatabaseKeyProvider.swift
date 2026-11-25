import Foundation
import Security

/// Supplies the SQLCipher key: 32 random bytes, generated once, stored only in wrapped form.
public struct DatabaseKeyProvider: Sendable {
    public static let account = "database-key.wrapped"

    private let store: any SecretStore
    private let wrapper: any KeyWrapper

    public init(store: any SecretStore, wrapper: any KeyWrapper) {
        self.store = store
        self.wrapper = wrapper
    }

    /// Returns the database key, creating and storing it (wrapped) on first use.
    public func key() throws -> Data {
        if let wrapped = try store.data(for: Self.account) {
            return try wrapper.unwrap(wrapped)
        }
        let key = try Self.randomBytes(32)
        try store.set(try wrapper.wrap(key), for: Self.account)
        return key
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw SealedStorageError.randomFailed(status) }
        return Data(bytes)
    }
}

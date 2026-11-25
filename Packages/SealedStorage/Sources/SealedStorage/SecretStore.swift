import Foundation
import Security

public enum SealedStorageError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case secureEnclaveUnavailable
    case keyWrap(String)
    case randomFailed(OSStatus)
    case databaseLocked
}

/// Somewhere to keep small secrets (wrapped keys, identity keys) by name.
public protocol SecretStore: Sendable {
    func data(for account: String) throws -> Data?
    func set(_ data: Data, for account: String) throws
    func delete(_ account: String) throws
}

/// Keychain generic-password items, readable only while the device is unlocked, never synced,
/// never restored to another device (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String) { self.service = service }

    private func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func data(for account: String) throws -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SealedStorageError.keychain(status) }
        return result as? Data
    }

    public func set(_ data: Data, for account: String) throws {
        try delete(account)
        var attributes = base(account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SealedStorageError.keychain(status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SealedStorageError.keychain(status) }
    }

    /// The accessibility class stored for an item (for tests and diagnostics).
    public func accessibility(of account: String) throws -> String? {
        var query = base(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SealedStorageError.keychain(status) }
        return (result as? [String: Any])?[kSecAttrAccessible as String] as? String
    }
}

/// In-memory store for tests and previews.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func data(for account: String) throws -> Data? { lock.withLock { items[account] } }
    public func set(_ data: Data, for account: String) throws { lock.withLock { items[account] = data } }
    public func delete(_ account: String) throws { lock.withLock { items[account] = nil } }
}

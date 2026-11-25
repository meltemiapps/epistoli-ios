import Foundation
import Security

/// Encrypts small secrets to a P-256 key so they can be stored at rest.
public protocol KeyWrapper: Sendable {
    func wrap(_ secret: Data) throws -> Data
    func unwrap(_ wrapped: Data) throws -> Data
}

private let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM

/// ECIES with a P-256 private key.
///
/// On a device the key is created inside the Secure Enclave and never leaves it.
/// The simulator has no Secure Enclave, so there (and only there) a software key in the Keychain is used.
/// Both are `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
public final class SecureEnclaveKeyWrapper: KeyWrapper, @unchecked Sendable {
    private let privateKey: SecKey
    private let publicKey: SecKey

    /// Whether this wrapper's key is in the Secure Enclave.
    public let isHardwareBacked: Bool

    /// Loads the key with `tag`, creating it on first use.
    public convenience init(tag: String) throws {
        #if targetEnvironment(simulator)
        let hardware = false
        #else
        let hardware = true
        #endif
        let key = try Self.loadKey(tag: tag) ?? Self.createKey(tag: tag, secureEnclave: hardware)
        try self.init(privateKey: key, isHardwareBacked: hardware)
    }

    /// A throwaway software key that is never stored. For tests.
    public static func ephemeral() throws -> SecureEnclaveKeyWrapper {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SealedStorageError.keyWrap(Self.describe(error))
        }
        return try SecureEnclaveKeyWrapper(privateKey: key, isHardwareBacked: false)
    }

    /// Where the stored key with `tag` lives, read back from the Keychain: `kSecAttrTokenIDSecureEnclave`
    /// for a Secure Enclave key, `nil` for a software key or no key. Used to prove the hardware path on devices.
    public static func storedKeyTokenID(tag: String) throws -> String? {
        var q = query(tag: tag)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SealedStorageError.keychain(status) }
        return (result as? [String: Any])?[kSecAttrTokenID as String] as? String
    }

    /// Deletes the stored key with `tag`. Anything wrapped with it becomes unrecoverable.
    public static func deleteKey(tag: String) {
        SecItemDelete(query(tag: tag) as CFDictionary)
    }

    init(privateKey: SecKey, isHardwareBacked: Bool) throws {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else {
            throw SealedStorageError.keyWrap("key does not support ECIES")
        }
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.isHardwareBacked = isHardwareBacked
    }

    public func wrap(_ secret: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let out = SecKeyCreateEncryptedData(publicKey, algorithm, secret as CFData, &error) else {
            throw SealedStorageError.keyWrap(Self.describe(error))
        }
        return out as Data
    }

    public func unwrap(_ wrapped: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let out = SecKeyCreateDecryptedData(privateKey, algorithm, wrapped as CFData, &error) else {
            throw SealedStorageError.keyWrap(Self.describe(error))
        }
        return out as Data
    }

    private static func query(tag: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func loadKey(tag: String) throws -> SecKey? {
        var q = query(tag: tag)
        q[kSecReturnRef as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item else { throw SealedStorageError.keychain(status) }
        return (item as! SecKey)
    }

    private static func createKey(tag: String, secureEnclave: Bool) throws -> SecKey {
        var error: Unmanaged<CFError>?
        let flags: SecAccessControlCreateFlags = secureEnclave ? [.privateKeyUsage] : []
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            throw SealedStorageError.keyWrap(describe(error))
        }
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data(tag.utf8),
                kSecAttrAccessControl as String: access,
            ] as [String: Any],
        ]
        if secureEnclave {
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        }
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw secureEnclave ? SealedStorageError.secureEnclaveUnavailable : SealedStorageError.keyWrap(describe(error))
        }
        return key
    }

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error = error?.takeRetainedValue() else { return "unknown" }
        return (error as Error).localizedDescription
    }
}

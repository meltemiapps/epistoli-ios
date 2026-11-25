import Foundation
import Security
import Testing
import SealedCrypto
import SealedStorage

/// Keychain and Secure Enclave paths need a real app host, so they run here, not in `swift test`.
@Suite(.serialized) struct KeychainTests {
    private let store = KeychainStore(service: "tests.\(UUID().uuidString)")

    @Test func storesWhenUnlockedThisDeviceOnly() throws {
        try store.set(Data("secret".utf8), for: "item")
        defer { try? store.delete("item") }
        #expect(try store.data(for: "item") == Data("secret".utf8))
        #expect(try store.accessibility(of: "item") == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    @Test func deleteRemovesItem() throws {
        try store.set(Data("x".utf8), for: "gone")
        try store.delete("gone")
        #expect(try store.data(for: "gone") == nil)
    }

    @Test func databaseKeySurvivesRelaunch() throws {
        let tag = "tests.dbkey.\(UUID().uuidString)"
        defer { SecureEnclaveKeyWrapper.deleteKey(tag: tag); try? store.delete(DatabaseKeyProvider.account) }
        let first = try DatabaseKeyProvider(store: store, wrapper: try SecureEnclaveKeyWrapper(tag: tag)).key()
        // A new wrapper instance loads the same stored P-256 key, as after an app relaunch.
        let second = try DatabaseKeyProvider(store: store, wrapper: try SecureEnclaveKeyWrapper(tag: tag)).key()
        #expect(first == second)
        #expect(first.count == 32)
    }

    @Test func wrapperIsHardwareBackedOnDevicesOnly() throws {
        let tag = "tests.hw.\(UUID().uuidString)"
        defer { SecureEnclaveKeyWrapper.deleteKey(tag: tag) }
        let wrapper = try SecureEnclaveKeyWrapper(tag: tag)
        #if targetEnvironment(simulator)
        #expect(!wrapper.isHardwareBacked)
        #else
        #expect(wrapper.isHardwareBacked)
        #endif
    }

    /// Checkpoint E: on a real device this must prove the database key is wrapped by a Secure Enclave key.
    @Test func databaseKeyIsWrappedBySecureEnclaveKeyOnDevice() throws {
        let tag = "tests.se.\(UUID().uuidString)"
        defer { SecureEnclaveKeyWrapper.deleteKey(tag: tag); try? store.delete(DatabaseKeyProvider.account) }
        let key = try DatabaseKeyProvider(store: store, wrapper: try SecureEnclaveKeyWrapper(tag: tag)).key()
        #expect(key.count == 32)
        let tokenID = try SecureEnclaveKeyWrapper.storedKeyTokenID(tag: tag)
        #if targetEnvironment(simulator)
        #expect(tokenID == nil, "simulator uses the software fallback")
        #else
        #expect(tokenID == kSecAttrTokenIDSecureEnclave as String, "device must use the Secure Enclave, got \(tokenID ?? "software key")")
        #endif
    }

    @Test func identityKeyRoundTripsThroughKeychain() throws {
        let identity = try SealedCrypto.generateIdentity(name: "test")
        try store.set(identity.data, for: "identity")
        defer { try? store.delete("identity") }
        let loaded = PGPPrivateKey(data: try #require(try store.data(for: "identity")))
        #expect(try SealedCrypto.publicKey(of: loaded).fingerprint == SealedCrypto.publicKey(of: identity).fingerprint)
    }
}

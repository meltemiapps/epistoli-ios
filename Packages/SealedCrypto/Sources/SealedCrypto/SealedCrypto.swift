import Foundation
import EpistoliPGP

/// An identity (private) key as binary OpenPGP packets. Store it only in the Keychain.
public struct PGPPrivateKey: Sendable {
    public let data: Data
    public init(data: Data) { self.data = data }
}

/// A contact's (or our own) public key as binary OpenPGP packets.
public struct PGPPublicKey: Sendable, Hashable {
    public let data: Data
    public let fingerprint: Fingerprint

    /// Parses binary public key packets. Throws if they are not a valid key.
    public init(data: Data) throws {
        self.data = data
        self.fingerprint = Fingerprint(hex: try call { PgpbridgeFingerprint(data, $0) })
    }
}

/// An OpenPGP v4 fingerprint (40 hex digits).
public struct Fingerprint: Sendable, Hashable, CustomStringConvertible {
    /// Lowercase hex, no spaces.
    public let hex: String

    public init(hex: String) { self.hex = hex.lowercased() }

    /// Uppercase, in groups of 4 separated by spaces, for showing to people.
    public var grouped: String {
        let chars = Array(hex.uppercased())
        return stride(from: 0, to: chars.count, by: 4)
            .map { String(chars[$0..<min($0 + 4, chars.count)]) }
            .joined(separator: " ")
    }

    public var description: String { grouped }
}

public enum SealedCryptoError: Error, Equatable, Sendable {
    /// The signature is missing, from someone else, or the data was tampered with.
    case signatureInvalid(String)
    /// We are not a recipient, or the message is damaged.
    case decryptionFailed(String)
    /// A key could not be parsed or used.
    case invalidKey(String)
    case other(String)

    init(_ error: NSError?) {
        let message = error?.localizedDescription ?? "unknown error"
        if message.hasPrefix(PgpbridgeErrPrefixSignature) { self = .signatureInvalid(message) }
        else if message.hasPrefix(PgpbridgeErrPrefixDecrypt) { self = .decryptionFailed(message) }
        else if message.hasPrefix(PgpbridgeErrPrefixKey) { self = .invalidKey(message) }
        else { self = .other(message) }
    }
}

/// Calls a gomobile function that reports failure through an NSError out-parameter.
private func call<T>(_ body: (AutoreleasingUnsafeMutablePointer<NSError?>) -> T?) throws -> T {
    var error: NSError?
    let result = body(&error)
    if let error { throw SealedCryptoError(error) }
    guard let result else { throw SealedCryptoError(nil) }
    return result
}

/// OpenPGP operations (GopenPGP v3, Curve25519 keys).
public enum SealedCrypto {
    /// The GopenPGP version compiled into the app.
    public static var libraryVersion: String { PgpbridgeLibraryVersion() }

    /// Generates a new identity key (EdDSA/Curve25519 signing key with an ECDH/Curve25519 subkey).
    public static func generateIdentity(name: String) throws -> PGPPrivateKey {
        PGPPrivateKey(data: try call { PgpbridgeGenerateKey(name, $0) })
    }

    public static func publicKey(of key: PGPPrivateKey) throws -> PGPPublicKey {
        try PGPPublicKey(data: try call { PgpbridgePublicKey(key.data, $0) })
    }

    /// Encrypts to every recipient and signs with the sender's key. Returns a binary OpenPGP message.
    /// Include the sender's own public key in `recipients` to be able to read sent messages later.
    public static func encrypt(_ plaintext: Data, to recipients: [PGPPublicKey], signedBy sender: PGPPrivateKey) throws -> Data {
        guard let list = PgpbridgeNewRecipients() else { throw SealedCryptoError.other("cannot create recipient list") }
        for recipient in recipients {
            try list.add(recipient.data)
        }
        return try call { PgpbridgeEncryptAndSign(plaintext, list, sender.data, $0) }
    }

    /// Decrypts and requires a valid signature from `sender`. Never returns unverified plaintext.
    public static func decrypt(_ ciphertext: Data, with key: PGPPrivateKey, verifyingSender sender: PGPPublicKey) throws -> Data {
        try call { PgpbridgeDecryptAndVerify(ciphertext, key.data, sender.data, $0) }
    }

    /// A binary detached signature.
    public static func sign(_ data: Data, with key: PGPPrivateKey) throws -> Data {
        try call { PgpbridgeSignDetached(data, key.data, $0) }
    }

    /// Throws `SealedCryptoError.signatureInvalid` unless `signature` is a valid signature over `data` by `signer`.
    public static func verify(_ data: Data, signature: Data, by signer: PGPPublicKey) throws {
        var error: NSError?
        if !PgpbridgeVerifyDetached(data, signature, signer.data, &error) {
            throw SealedCryptoError(error)
        }
    }

    /// Exports a public key as an ASCII-armoured block.
    public static func armored(_ key: PGPPublicKey) throws -> String {
        try call { PgpbridgeArmorPublicKey(key.data, $0) }
    }

    /// Imports binary public key packets received from someone else (for example in a contact code).
    /// Rejects private keys and keys that cannot encrypt and verify.
    public static func importPublicKey(_ data: Data) throws -> PGPPublicKey {
        try PGPPublicKey(data: try call { PgpbridgeImportPublicKey(data, $0) })
    }

    /// Imports an ASCII-armoured public key. Rejects private keys and keys that cannot encrypt and verify.
    public static func importArmored(_ armored: String) throws -> PGPPublicKey {
        try PGPPublicKey(data: try call { PgpbridgeImportArmoredPublicKey(armored, $0) })
    }
}

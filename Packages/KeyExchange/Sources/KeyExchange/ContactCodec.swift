import Foundation
import EpistoliCore
import SealedCrypto

public enum ContactCodeError: Error, Equatable, Sendable {
    /// Not one of our codes (some other QR code or text).
    case notAContactCode
    /// Made by a newer version of the app.
    case unsupportedVersion
    /// Damaged or incomplete.
    case damaged
    /// The key could not be used: a private key, expired, revoked or not a key at all.
    case invalidKey
    /// The fingerprint in the code does not match its key.
    case fingerprintMismatch
}

/// Turns our identity into "My code" text, and scanned or pasted text into a checked key offer.
public enum ContactCodec {
    /// The text in "My code". Built from the public key only; the private key cannot reach it.
    public static func code(for identity: Identity) throws -> String {
        try code(displayName: identity.displayName, address: identity.address, publicKey: identity.publicKey)
    }

    public static func code(displayName: String, address: TransportAddress, publicKey: PGPPublicKey) throws -> String {
        guard let fingerprint = Data(hex: publicKey.fingerprint.hex) else { throw ContactCodeError.fingerprintMismatch }
        do {
            return try ContactCode(fingerprint: fingerprint, address: address, displayName: displayName,
                                   publicKey: publicKey.data).text()
        } catch {
            throw ContactCodeError.damaged
        }
    }

    /// Parses and checks a code: the key must be a usable public key whose fingerprint matches.
    /// `source` is `.scannedInPerson` only for the camera; anything pasted is `.receivedOtherwise`.
    public static func read(_ text: String, source: KeySource) throws(ContactCodeError) -> OfferedKey {
        let code: ContactCode
        do {
            code = try ContactCode(text: text)
        } catch .notAContactCode {
            throw .notAContactCode
        } catch .unsupportedVersion {
            throw .unsupportedVersion
        } catch {
            throw .damaged
        }
        let key: PGPPublicKey
        do { key = try SealedCrypto.importPublicKey(code.publicKey) } catch { throw .invalidKey }
        guard key.fingerprint.hex == code.fingerprint.hexString else { throw .fingerprintMismatch }
        let name = code.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return OfferedKey(displayName: name.isEmpty ? "?" : name, address: code.address,
                          fingerprint: key.fingerprint.hex, publicKey: key.data, source: source)
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

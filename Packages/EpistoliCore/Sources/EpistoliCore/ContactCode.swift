import Foundation

/// The contents of a "My code" QR code: what someone needs to add you as a contact.
///
/// It holds a public key, never a private key. The key itself is checked (parsed, private keys
/// rejected, fingerprint compared) by the KeyExchange package; this type only handles the encoding.
/// Format: docs/CONTACT_CODE.md.
public struct ContactCode: Equatable, Sendable {
    public static let version: UInt8 = 1
    /// Marks the text as a contact code. Upper case so it stays in the QR alphanumeric set.
    public static let prefix = "KEY:"
    /// Ends the text, so trimming a trailing space (a valid Base45 character) is detectable.
    public static let terminator: Character = "."

    public static let maxNameBytes = 64
    public static let maxAddressBytes = 128
    public static let maxPublicKeyBytes = 4096

    /// OpenPGP v4 fingerprint, 20 bytes.
    public let fingerprint: Data
    /// Where messages for this person go (see `TransportAddress`).
    public let address: TransportAddress
    /// The name the person chose to show. Shown as a suggestion; the scanner can rename the contact.
    public let displayName: String
    /// Binary OpenPGP public key packets.
    public let publicKey: Data

    public enum DecodingError: Error, Equatable, Sendable {
        case notAContactCode
        case unsupportedVersion(UInt8)
        case malformed
        case tooLong
    }

    public init(fingerprint: Data, address: TransportAddress, displayName: String, publicKey: Data) {
        self.fingerprint = fingerprint
        self.address = address
        self.displayName = displayName
        self.publicKey = publicKey
    }

    // MARK: Binary form

    /// version (1) | fingerprint (20) | address length (1) | address | name length (1) | name |
    /// key length (2, big-endian) | key. Lengths are in bytes; strings are UTF-8.
    public func binary() throws(DecodingError) -> Data {
        let address = Data(self.address.rawValue.utf8)
        let name = Data(Self.truncated(displayName, toBytes: Self.maxNameBytes).utf8)
        guard fingerprint.count == 20 else { throw .malformed }
        guard address.count <= Self.maxAddressBytes, publicKey.count <= Self.maxPublicKeyBytes else { throw .tooLong }
        var out = Data([Self.version])
        out.append(fingerprint)
        out.append(UInt8(address.count)); out.append(address)
        out.append(UInt8(name.count)); out.append(name)
        out.append(UInt8(publicKey.count >> 8)); out.append(UInt8(publicKey.count & 0xFF)); out.append(publicKey)
        return out
    }

    public init(binary data: Data) throws(DecodingError) {
        var reader = Reader(bytes: [UInt8](data))
        let version = try reader.byte()
        guard version == Self.version else { throw .unsupportedVersion(version) }
        let fingerprint = try reader.take(20)
        let addressLength = Int(try reader.byte())
        guard addressLength <= Self.maxAddressBytes else { throw .tooLong }
        guard let addressString = String(bytes: try reader.take(addressLength), encoding: .utf8),
              let address = TransportAddress(rawValue: addressString) else { throw .malformed }
        let nameLength = Int(try reader.byte())
        guard nameLength <= Self.maxNameBytes else { throw .tooLong }
        guard let name = String(bytes: try reader.take(nameLength), encoding: .utf8) else { throw .malformed }
        let keyLength = Int(try reader.byte()) << 8 | Int(try reader.byte())
        guard keyLength > 0, keyLength <= Self.maxPublicKeyBytes else { throw .malformed }
        let key = try reader.take(keyLength)
        guard reader.isAtEnd else { throw .malformed }
        self.init(fingerprint: Data(fingerprint), address: address, displayName: name, publicKey: Data(key))
    }

    // MARK: Text form (what the QR code and a copied code contain)

    /// `KEY:` + Base45(binary) + `.`
    public func text() throws(DecodingError) -> String {
        Self.prefix + Base45.encode(try binary()) + String(Self.terminator)
    }

    /// Parses a scanned or pasted code. Leading and trailing whitespace and line breaks are ignored.
    public init(text: String) throws(DecodingError) {
        var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard s.hasPrefix(Self.prefix), s.last == Self.terminator else { throw .notAContactCode }
        s = s.dropFirst(Self.prefix.count).dropLast()
        let data: Data
        do { data = try Base45.decode(String(s)) } catch { throw .malformed }
        try self.init(binary: data)
    }

    /// Cuts a string to at most `limit` UTF-8 bytes without splitting a character.
    static func truncated(_ s: String, toBytes limit: Int) -> String {
        var out = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > limit { break }
            out.append(ch)
            used += n
        }
        return out
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var isAtEnd: Bool { index == bytes.count }

        mutating func byte() throws(DecodingError) -> UInt8 {
            guard index < bytes.count else { throw .malformed }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func take(_ n: Int) throws(DecodingError) -> ArraySlice<UInt8> {
            guard n >= 0, index + n <= bytes.count else { throw .malformed }
            defer { index += n }
            return bytes[index..<index + n]
        }
    }
}

/// Where a person's messages are delivered: `scheme:value`.
/// v1 schemes: `loopback` (a shared folder, for development, section 4) and, from section 5, `icloud`.
public struct TransportAddress: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public var scheme: Substring { rawValue.prefix { $0 != ":" } }
    public var value: Substring { rawValue.drop { $0 != ":" }.dropFirst() }
    public var description: String { rawValue }

    public init?(rawValue: String) {
        guard let colon = rawValue.firstIndex(of: ":"), colon != rawValue.startIndex,
              rawValue.index(after: colon) != rawValue.endIndex,
              rawValue.utf8.count <= ContactCode.maxAddressBytes,
              rawValue.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) else { return nil }
        self.rawValue = rawValue
    }

    public init?(scheme: String, value: String) {
        self.init(rawValue: scheme + ":" + value)
    }
}

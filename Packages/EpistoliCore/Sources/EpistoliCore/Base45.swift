import Foundation

/// Base45 (RFC 9285). Its 45 characters are exactly the QR code alphanumeric set, so a QR code
/// can store the text in alphanumeric mode (5.5 bits per character), which is denser than
/// Base64 in byte mode.
public enum Base45 {
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".utf8)
    private static let values: [UInt8: Int] = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    public enum DecodingError: Error, Equatable, Sendable {
        case invalidCharacter
        case invalidLength
        case valueOutOfRange
    }

    public static func encode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count / 2 * 3 + 2)
        var i = 0
        while i + 1 < bytes.count {
            var n = Int(bytes[i]) * 256 + Int(bytes[i + 1])
            for _ in 0..<3 {
                out.append(alphabet[n % 45])
                n /= 45
            }
            i += 2
        }
        if i < bytes.count {
            let n = Int(bytes[i])
            out.append(alphabet[n % 45])
            out.append(alphabet[n / 45])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func decode(_ string: String) throws(DecodingError) -> Data {
        let chars = Array(string.utf8)
        guard chars.count % 3 != 1 else { throw .invalidLength }
        var digits: [Int] = []
        digits.reserveCapacity(chars.count)
        for c in chars {
            guard let v = values[c] else { throw .invalidCharacter }
            digits.append(v)
        }
        var out = Data(capacity: chars.count / 3 * 2 + 1)
        var i = 0
        while i + 2 < digits.count {
            let n = digits[i] + digits[i + 1] * 45 + digits[i + 2] * 45 * 45
            guard n <= 0xFFFF else { throw .valueOutOfRange }
            out.append(UInt8(n >> 8))
            out.append(UInt8(n & 0xFF))
            i += 3
        }
        if i < digits.count {
            let n = digits[i] + digits[i + 1] * 45
            guard n <= 0xFF else { throw .valueOutOfRange }
            out.append(UInt8(n))
        }
        return out
    }
}

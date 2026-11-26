import Foundation
import GRDB
import SealedCrypto

/// Looks for a private key in files, database contents and text, in the encodings a leak would
/// most likely use: raw binary, hex, Base64 (which is also the body of an armoured key) and the
/// armour header itself.
///
/// It searches for pieces of the private key that are not part of the public key, so a public key
/// (which is meant to be everywhere) never counts as a leak. Any run of about 20 secret bytes is found.
public struct PrivateKeyLeakScanner: Sendable {
    public struct Finding: Equatable, Sendable, CustomStringConvertible {
        public let location: String
        public let encoding: String
        public var description: String { "\(encoding) private key material in \(location)" }
    }

    private struct Needle: Sendable {
        let encoding: String
        let bytes: Data
    }

    private let needles: [Needle]

    /// Number of distinct pieces searched for (a sanity check for tests).
    public var needleCount: Int { needles.count }

    public init(privateKey: PGPPrivateKey, publicKey: PGPPublicKey) {
        let priv = [UInt8](privateKey.data)
        let pub = publicKey.data
        var needles: [Needle] = [Needle(encoding: "armour", bytes: Data("PRIVATE KEY BLOCK".utf8))]

        // Binary windows that exist in the private key but not in the public key.
        let width = 16
        var secretWindows: [Data] = []
        for start in stride(from: 0, through: priv.count - width, by: 4) {
            let window = Data(priv[start..<start + width])
            if pub.range(of: window) == nil { secretWindows.append(window) }
        }
        for w in secretWindows {
            needles.append(Needle(encoding: "binary", bytes: w))
            let hex = w.map { String(format: "%02x", $0) }.joined()
            needles.append(Needle(encoding: "hex", bytes: Data(hex.utf8)))
            needles.append(Needle(encoding: "hex", bytes: Data(hex.uppercased().utf8)))
        }

        // Base64 at all three byte alignments, in 24-character pieces (18 bytes) that never
        // appear in the public key's Base64.
        let publicBase64 = (0..<3).map { pub.dropFirst($0).base64EncodedString() }
        for offset in 0..<3 {
            let b64 = Array(Data(priv.dropFirst(offset)).base64EncodedString().utf8)
            for start in stride(from: 0, to: b64.count - 24, by: 4) {
                let piece = String(decoding: b64[start..<start + 24], as: UTF8.self)
                if !publicBase64.contains(where: { $0.contains(piece) }) {
                    needles.append(Needle(encoding: "base64", bytes: Data(piece.utf8)))
                }
            }
        }
        self.needles = needles
    }

    /// The encodings of private key material found in `data`.
    public func encodingsFound(in data: Data) -> Set<String> {
        var found: Set<String> = []
        for needle in needles where !found.contains(needle.encoding) {
            if data.range(of: needle.bytes) != nil { found.insert(needle.encoding) }
        }
        return found
    }

    public func findings(inText text: String, location: String) -> [Finding] {
        encodingsFound(in: Data(text.utf8)).sorted().map { Finding(location: location, encoding: $0) }
    }

    /// Every regular file under `root`, recursively, including hidden files.
    public func scanFiles(under root: URL) throws -> (findings: [Finding], filesScanned: Int) {
        var findings: [Finding] = []
        var count = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return ([], 0)
        }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            // Files the system holds open exclusively are skipped; everything we write is readable.
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            count += 1
            let relative = url.path.replacingOccurrences(of: root.path, with: "")
            findings += encodingsFound(in: data).sorted().map { Finding(location: relative, encoding: $0) }
        }
        return (findings, count)
    }

    /// Every text and blob value in every table of an open (decrypted) database.
    public func scanDatabase(_ reader: any DatabaseReader) throws -> (findings: [Finding], valuesScanned: Int) {
        try reader.read { db in
            var findings: [Finding] = []
            var count = 0
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            for table in tables {
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table.quotedDatabaseIdentifier)")
                for row in rows {
                    for (column, value) in row {
                        let data: Data
                        switch value.storage {
                        case .blob(let blob): data = blob
                        case .string(let s): data = Data(s.utf8)
                        default: continue
                        }
                        count += 1
                        findings += encodingsFound(in: data).sorted().map { Finding(location: "\(table).\(column)", encoding: $0) }
                    }
                }
            }
            return (findings, count)
        }
    }
}

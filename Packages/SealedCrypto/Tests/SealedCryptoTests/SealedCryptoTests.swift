import Foundation
import Testing
@testable import SealedCrypto

@Suite struct SealedCryptoTests {
    private func identity(_ name: String) throws -> (PGPPrivateKey, PGPPublicKey) {
        let priv = try SealedCrypto.generateIdentity(name: name)
        return (priv, try SealedCrypto.publicKey(of: priv))
    }

    @Test func roundTripToThreeRecipients() throws {
        let (sender, senderPub) = try identity("sender")
        let recipients = try ["a", "b", "c"].map(identity)
        let message = Data("Γεια σου, family".utf8)
        let ciphertext = try SealedCrypto.encrypt(message, to: recipients.map(\.1), signedBy: sender)
        #expect(ciphertext != message)
        for (priv, _) in recipients {
            #expect(try SealedCrypto.decrypt(ciphertext, with: priv, verifyingSender: senderPub) == message)
        }
    }

    @Test func nonRecipientCannotDecrypt() throws {
        let (sender, senderPub) = try identity("sender")
        let (_, pub) = try identity("a")
        let (outsider, _) = try identity("outsider")
        let ciphertext = try SealedCrypto.encrypt(Data("hi".utf8), to: [pub], signedBy: sender)
        #expect {
            try SealedCrypto.decrypt(ciphertext, with: outsider, verifyingSender: senderPub)
        } throws: { error in
            if case .decryptionFailed = error as? SealedCryptoError { return true }
            return false
        }
    }

    @Test func tamperedSignatureIsRejected() throws {
        let (key, pub) = try identity("signer")
        let data = Data("envelope".utf8)
        var signature = try SealedCrypto.sign(data, with: key)
        try SealedCrypto.verify(data, signature: signature, by: pub)

        signature[signature.count - 5] ^= 0xFF
        #expect {
            try SealedCrypto.verify(data, signature: signature, by: pub)
        } throws: { error in
            if case .signatureInvalid = error as? SealedCryptoError { return true }
            return false
        }
    }

    @Test func tamperedDataIsRejected() throws {
        let (key, pub) = try identity("signer")
        var data = Data("envelope".utf8)
        let signature = try SealedCrypto.sign(data, with: key)
        data[0] ^= 1
        #expect(throws: SealedCryptoError.self) { try SealedCrypto.verify(data, signature: signature, by: pub) }
    }

    @Test func wrongSenderIsRejected() throws {
        let (sender, _) = try identity("sender")
        let (_, impostorPub) = try identity("impostor")
        let (priv, pub) = try identity("a")
        let ciphertext = try SealedCrypto.encrypt(Data("hi".utf8), to: [pub], signedBy: sender)
        #expect {
            try SealedCrypto.decrypt(ciphertext, with: priv, verifyingSender: impostorPub)
        } throws: { error in
            if case .signatureInvalid = error as? SealedCryptoError { return true }
            return false
        }
    }

    @Test func armouredExportAndImport() throws {
        let (_, pub) = try identity("me")
        let armored = try SealedCrypto.armored(pub)
        #expect(armored.hasPrefix("-----BEGIN PGP PUBLIC KEY BLOCK-----"))
        #expect(!armored.contains("PRIVATE"))
        let imported = try SealedCrypto.importArmored(armored)
        #expect(imported.fingerprint == pub.fingerprint)
    }

    @Test func importRejectsGarbage() {
        #expect(throws: SealedCryptoError.self) { try SealedCrypto.importArmored("not a key") }
    }

    @Test func fingerprintFormat() throws {
        let (_, pub) = try identity("me")
        #expect(pub.fingerprint.hex.count == 40)
        let groups = pub.fingerprint.grouped.split(separator: " ")
        #expect(groups.count == 10)
        #expect(groups.allSatisfy { $0.count == 4 && $0 == $0.uppercased() })
    }

    @Test func groupingOfKnownFingerprint() {
        let fp = Fingerprint(hex: "0123456789abcdef0123456789abcdef01234567")
        #expect(fp.grouped == "0123 4567 89AB CDEF 0123 4567 89AB CDEF 0123 4567")
    }

    @Test func binaryImportAcceptsPublicRejectsPrivate() throws {
        let (priv, pub) = try identity("me")
        let imported = try SealedCrypto.importPublicKey(pub.data)
        #expect(imported == pub)
        #expect(throws: SealedCryptoError.self) { try SealedCrypto.importPublicKey(priv.data) }
        #expect(throws: SealedCryptoError.self) { try SealedCrypto.importPublicKey(Data("junk".utf8)) }
    }

    @Test func libraryVersionIsPinned() {
        #expect(SealedCrypto.libraryVersion == "3.5.2")
    }
}

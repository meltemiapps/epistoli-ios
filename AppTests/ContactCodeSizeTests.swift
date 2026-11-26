import Foundation
import Testing
import KeyExchange
import SealedStorage
@testable import Epistoli

/// The size of "My code", reported in docs/CONTACT_CODE.md.
@Suite struct ContactCodeSizeTests {
    @Test(arguments: ["Μαρία", "Μαρία Παπαδοπούλου-Κωνσταντινίδου"])
    func codeFitsAComfortableQRVersion(name: String) throws {
        let me = try IdentityStore(store: MemorySecretStore(), wrapper: SecureEnclaveKeyWrapper.ephemeral()).create(displayName: name)
        let code = try ContactCodec.code(for: me)
        let version = try #require(QRCodeImage.version(for: code))
        print("contact code for \(name.count)-character name: \(code.count) characters, QR version \(version) (\(17 + 4 * version) modules), level M")
        #expect(version <= 20)
        #expect(QRCodeImage.render(code) != nil)
    }
}

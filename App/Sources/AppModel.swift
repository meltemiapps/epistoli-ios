import Foundation
import Observation
import EpistoliCore
import KeyExchange
import Security
import SealedStorage

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case failed(String)
        case onboarding
        case ready
    }

    private(set) var phase: Phase
    private(set) var identity: Identity?
    private(set) var contacts: [Contact] = []
    private let env: AppEnvironment?

    init(environment: () throws -> AppEnvironment = AppEnvironment.live) {
        var env: AppEnvironment?
        var identity: Identity?
        var contacts: [Contact] = []
        var phase = Phase.onboarding
        do {
            let opened = try environment()
            identity = try opened.identities.load()
            contacts = try opened.contacts.all()
            env = opened
            phase = identity == nil ? .onboarding : .ready
        } catch {
            phase = .failed(String(describing: error))
        }
        self.env = env
        self.identity = identity
        self.contacts = contacts
        self.phase = phase
    }

    // MARK: Identity

    func createIdentity(name: String) throws {
        guard let env else { return }
        identity = try env.identities.create(displayName: name)
        phase = .ready
    }

    /// Where the key that wraps the database key and the identity key actually lives, read back
    /// from the Keychain. Shown in Settings; on a device it must say Secure Enclave (Checkpoint E).
    var keyProtection: String {
        guard let env else { return "Unavailable" }
        do {
            let token = try SecureEnclaveKeyWrapper.storedKeyTokenID(tag: env.wrapperTag)
            return token == (kSecAttrTokenIDSecureEnclave as String) ? "Secure Enclave" : "Software key (simulator only)"
        } catch {
            return "Unknown (\(error))"
        }
    }

    func myCode() throws -> String {
        guard let identity else { throw IdentityError.emptyName }
        return try ContactCodec.code(for: identity)
    }

    #if DEBUG
    /// Debug builds only: a new key for the same name and address, as a new phone would have.
    func simulateNewPhone() throws {
        guard let env, let identity else { return }
        self.identity = try env.identities.replaceKey(of: identity)
    }
    #endif

    // MARK: Contacts

    /// What accepting `offer` would do, without saving anything.
    func preview(_ offer: OfferedKey) -> Result<(contact: Contact, outcome: KeyOfferOutcome), KeyOfferError> {
        guard let identity else { return .failure(.ownCode) }
        let existing = contacts.first { $0.address == offer.address }
        let sameKey = contacts.first { $0.currentKey.fingerprint == offer.fingerprint }
        return Result { () throws(KeyOfferError) in
            try ContactRules.apply(offer, to: existing, contactWithSameKey: sameKey,
                                   ownFingerprint: identity.fingerprint.hex, ownAddress: identity.address, now: Date())
        }
    }

    /// Saves `offer`. A new contact gets `name` (the scanner may change the suggested one).
    @discardableResult
    func accept(_ offer: OfferedKey, name: String? = nil) throws -> Contact {
        guard let env, let identity else { throw KeyOfferError.ownCode }
        let result = try env.contacts.offer(offer, from: identity)
        if result.outcome == .added, let name, name != result.contact.displayName {
            try env.contacts.rename(result.contact.id, to: name)
        }
        try reloadContacts()
        return contacts.first { $0.id == result.contact.id } ?? result.contact
    }

    func rename(_ contact: Contact, to name: String) throws {
        try env?.contacts.rename(contact.id, to: name)
        try reloadContacts()
    }

    func delete(_ contact: Contact) throws {
        try env?.contacts.delete(contact.id)
        try reloadContacts()
    }

    func contact(id: UUID) -> Contact? { contacts.first { $0.id == id } }

    private func reloadContacts() throws {
        guard let env else { return }
        contacts = try env.contacts.all()
    }
}

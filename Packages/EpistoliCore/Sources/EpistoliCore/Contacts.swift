import Foundation

/// How we got a key.
public enum KeySource: String, Codable, Sendable {
    /// Scanned with the camera from the person's own phone, in person.
    case scannedInPerson
    /// Pasted, or received any other way (a message, a photo of the code, the transport).
    case receivedOtherwise
}

public enum VerificationState: String, Sendable {
    /// The current key was scanned in person.
    case verified
    /// The current key arrived some other way.
    case unverified
}

/// One key a contact has used. A contact's keys are kept, oldest first; the last one is current.
public struct ContactKey: Equatable, Sendable {
    /// Lowercase hex fingerprint.
    public var fingerprint: String
    /// Binary OpenPGP public key packets.
    public var publicKey: Data
    public var source: KeySource
    public var firstSeen: Date
    /// When a newer key replaced this one; `nil` for the current key.
    public var replacedAt: Date?

    public init(fingerprint: String, publicKey: Data, source: KeySource, firstSeen: Date, replacedAt: Date? = nil) {
        self.fingerprint = fingerprint
        self.publicKey = publicKey
        self.source = source
        self.firstSeen = firstSeen
        self.replacedAt = replacedAt
    }
}

public struct Contact: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var displayName: String
    /// Identifies the person across key changes: a new phone gets a new key but keeps the address.
    public var address: TransportAddress
    /// Key history, oldest first. Never empty; the last element is the current key.
    public var keys: [ContactKey]
    /// Set when the key changed and the new key has not been scanned in person yet. Only a camera
    /// scan of the current key clears it (`ContactRules`); accepting a pasted key never does.
    /// While set, the contact is Unverified and every chat with them shows the key-change banner.
    public var keyChangedAt: Date?

    public init(id: UUID = UUID(), displayName: String, address: TransportAddress, keys: [ContactKey], keyChangedAt: Date? = nil) {
        precondition(!keys.isEmpty, "a contact needs a key")
        self.id = id
        self.displayName = displayName
        self.address = address
        self.keys = keys
        self.keyChangedAt = keyChangedAt
    }

    public var currentKey: ContactKey { keys[keys.count - 1] }

    /// Verified only when the current key was scanned in person and no key change is pending.
    /// The second condition is redundant with `ContactRules` today; it keeps a pending key change
    /// from ever showing as Verified if a future code path sets the two fields inconsistently.
    public var verification: VerificationState {
        currentKey.source == .scannedInPerson && keyChangedAt == nil ? .verified : .unverified
    }

    public var needsKeyChangeWarning: Bool { keyChangedAt != nil }
}

/// A key offered for a contact: from a scanned or pasted code (section 3) or, later, the transport.
/// The fingerprint must already have been checked against the key (KeyExchange does this).
public struct OfferedKey: Sendable {
    public var displayName: String
    public var address: TransportAddress
    public var fingerprint: String
    public var publicKey: Data
    public var source: KeySource

    public init(displayName: String, address: TransportAddress, fingerprint: String, publicKey: Data, source: KeySource) {
        self.displayName = displayName
        self.address = address
        self.fingerprint = fingerprint.lowercased()
        self.publicKey = publicKey
        self.source = source
    }
}

public enum KeyOfferOutcome: Equatable, Sendable {
    /// A new contact.
    case added
    /// Same key as before, nothing changed.
    case unchanged
    /// Same key, now scanned in person: the contact became Verified (and any key-change warning cleared).
    case verified
    /// A different key for a known contact. `warning` is false only when the new key was scanned in person.
    case keyChanged(warning: Bool)
}

public enum KeyOfferError: Error, Equatable, Sendable {
    /// The code is our own.
    case ownCode
    /// Another contact (different address) already uses this key.
    case keyBelongsToAnotherContact(name: String)
}

public enum ContactRules {
    /// Decides what an offered key does to the contact list. Pure: the caller persists the result.
    /// - Parameters:
    ///   - existing: the contact with the same address, if any.
    ///   - contactWithSameKey: any contact whose current key has this fingerprint.
    public static func apply(
        _ offer: OfferedKey,
        to existing: Contact?,
        contactWithSameKey: Contact?,
        ownFingerprint: String,
        ownAddress: TransportAddress,
        now: Date
    ) throws(KeyOfferError) -> (contact: Contact, outcome: KeyOfferOutcome) {
        if offer.fingerprint == ownFingerprint.lowercased() || offer.address == ownAddress { throw .ownCode }
        if let other = contactWithSameKey, other.address != offer.address {
            throw .keyBelongsToAnotherContact(name: other.displayName)
        }
        let newKey = ContactKey(fingerprint: offer.fingerprint, publicKey: offer.publicKey, source: offer.source, firstSeen: now)

        guard var contact = existing else {
            return (Contact(displayName: offer.displayName, address: offer.address, keys: [newKey]), .added)
        }

        if contact.currentKey.fingerprint == offer.fingerprint {
            if offer.source == .scannedInPerson && (contact.verification == .unverified || contact.needsKeyChangeWarning) {
                contact.keys[contact.keys.count - 1].source = .scannedInPerson
                contact.keyChangedAt = nil
                return (contact, .verified)
            }
            return (contact, .unchanged)
        }

        // A different key for this person, for example a new phone. Keep the old one in the history.
        contact.keys[contact.keys.count - 1].replacedAt = now
        contact.keys.append(newKey)
        let warning = offer.source != .scannedInPerson
        contact.keyChangedAt = warning ? now : nil
        return (contact, .keyChanged(warning: warning))
    }
}

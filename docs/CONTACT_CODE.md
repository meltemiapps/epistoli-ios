# Contact code ("My code")

The QR code a person shows so a family member can add them. It carries a **public** key, its fingerprint, a transport address and a suggested display name. It never carries a private key: the encoder takes only a public key, and the decoder refuses any code whose key packets are private (`ContactCodec.read` → `invalidKey`).

Code: `Packages/EpistoliCore/Sources/EpistoliCore/ContactCode.swift` (encoding) and `Packages/KeyExchange/Sources/KeyExchange/ContactCodec.swift` (key checks).

## Binary form (version 1)

| Field | Size | Notes |
|---|---|---|
| version | 1 byte | `0x01` |
| fingerprint | 20 bytes | OpenPGP v4 fingerprint of the key below |
| address length | 1 byte | at most 128 |
| address | variable | UTF-8 `scheme:value`, printable ASCII. v1: `loopback:<32 hex>` (section 4), later `icloud:…` (section 5) |
| name length | 1 byte | at most 64 |
| name | variable | UTF-8, cut to 64 bytes on a character boundary |
| key length | 2 bytes | big-endian, 1 to 4096 |
| key | variable | binary OpenPGP public key packets (GopenPGP, Ed25519 primary key + X25519 subkey, v4) |

Nothing may follow the key. The key's OpenPGP user ID is always `-`: the name travels in the code and the profile, not in the key. That way the key reveals no name, a rename never needs a new key, and a Greek name (2 bytes per letter) is not stored twice.

## Text form

`KEY:` + Base45 (RFC 9285) of the binary form + `.`

Base45's 45 characters are exactly the QR alphanumeric set, so CoreImage encodes the text in alphanumeric mode (5.5 bits per character). That makes the QR code smaller than Base64 would (Base64 needs byte mode, 8 bits per character). The trailing `.` means a trimmed trailing space (a valid Base45 character) is detected rather than silently corrupting the code. The same text is what "Copy code as text" puts on the clipboard.

## Size

Measured by `KeyExchangeTests` and `EpistoliTests/ContactCodeSizeTests`:

| | Bytes / characters | QR (level M) |
|---|---|---|
| Public key | 483 bytes | |
| Binary code, 5-letter Greek name | about 560 bytes | |
| Text code, 5-letter Greek name | 844 characters | version 19, 93 × 93 modules |
| Text code, 33-letter Greek name | 925 characters | version 20, 97 × 97 modules |

Error correction is level M (about 15% of the symbol can be damaged, for example by screen glare).

## Checks on reading

1. `KEY:` prefix and `.` terminator, else "not a contact code" (some other QR code).
2. Version 1, else "made by a newer version".
3. Exact lengths, no trailing bytes, valid UTF-8 and address, else "damaged".
4. The key parses as a **public** key that can encrypt and verify now (not expired or revoked), else "invalid key".
5. The key's fingerprint equals the fingerprint field, else "doesn't match its key".

## Verification and key changes

- A code read by the camera is `scannedInPerson`: the contact is **Verified**. A pasted code is `receivedOtherwise`: **Unverified**. Scanning the same key in person later upgrades the contact. A pasted code never downgrades it.
- Contacts are identified by address. A new key for a known address (for example a new phone) is a **key change**: the old key stays in the key history, and unless the new key was scanned in person the contact shows a key-change warning until it is. The app warns before sending while the warning is set (section 4).
- Your own code, or a key already used by another contact, is refused.

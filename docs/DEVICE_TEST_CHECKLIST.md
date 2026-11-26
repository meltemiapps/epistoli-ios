# Real-device test checklist

Things that cannot be proven in the simulator or CI. Each item names the evidence to record.

## Checkpoint E (CloudKit transport, real iPhone)

- [ ] **Database key is wrapped by a Secure Enclave key, not the software fallback.**
  The simulator has no Secure Enclave, so `SecureEnclaveKeyWrapper` uses a software P-256 key there. That fallback is compiled only for `targetEnvironment(simulator)`. On a device, creating the key fails rather than falling back.
  1. In Xcode, select the iPhone as the run destination (signing team set, Developer Mode on).
  2. Run the test `EpistoliTests/KeychainTests/databaseKeyIsWrappedBySecureEnclaveKeyOnDevice()`. It creates a database key with `DatabaseKeyProvider`, then reads the wrapping key's attributes back from the Keychain. It must report `kSecAttrTokenID == kSecAttrTokenIDSecureEnclave`.
  3. Also check the app's real key: launch the app, create your key, open Settings and check **Your key › Protected by** says **Secure Enclave**. (It reads the wrapping key's token back from the Keychain. "Software key" on a device is a failure.)
  4. Record: device model, iOS version, test result line, and a screenshot of the Settings row.
- [ ] **Identity private key is stored exactly like the database key, and never leaks.**
  The OpenPGP private key is a Keychain item (`WhenUnlockedThisDeviceOnly`), wrapped by the same Secure Enclave key that wraps the database key.
  1. On the iPhone, run `EpistoliTests/IdentityKeyStorageTests` (all three tests).
     - `privateKeyIsAWrappedKeychainItemWhenUnlockedThisDeviceOnly()` checks the item's accessibility, that the stored bytes are ciphertext, that the wrapping key unwraps them after a relaunch, and that the wrapping key's token is `kSecAttrTokenIDSecureEnclave`.
     - `privateKeyIsNeverInTheDatabaseContainerLogsOrExports()` exports "My code" and the armoured public key, adds a contact, then searches the decrypted database (every value), every file in the app container (including the SQLCipher file and WAL) and this process's log for the private key as binary, hex, Base64 or an armour header.
     - `containerScanFindsAPlantedKey()` is the positive control: it plants the key in a file and the scan must find it.
  2. Record: device model, iOS version and the three result lines.
- [ ] **QR scan with the camera** (the simulator has no camera, so Checkpoint C used pasted codes). Scan another phone's "My code" in person; the contact must show **Verified**. Then on the other phone use Settings › Developer › Simulate new phone (Debug build), paste its new code: the warning must appear. Scan the new code in person: the warning must clear and the contact must be Verified again.
- [ ] Two-device CloudKit message exchange (section 5).
- [ ] Notification permission is asked when a chat is first opened, not at launch. Alerts say only "New message" (section 5).

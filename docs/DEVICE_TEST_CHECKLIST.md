# Real-device test checklist

Things that cannot be proven in the simulator or CI. Each item names the evidence to record.

## Checkpoint E (CloudKit transport, real iPhone)

- [ ] **Database key is wrapped by a Secure Enclave key, not the software fallback.**
  The simulator has no Secure Enclave, so `SecureEnclaveKeyWrapper` uses a software P-256 key there. That fallback is compiled only for `targetEnvironment(simulator)`. On a device, creating the key fails rather than falling back.
  1. In Xcode, select the iPhone as the run destination (signing team set, Developer Mode on).
  2. Run the test `EpistoliTests/KeychainTests/databaseKeyIsWrappedBySecureEnclaveKeyOnDevice()`. It creates a database key with `DatabaseKeyProvider`, then reads the wrapping key's attributes back from the Keychain. It must report `kSecAttrTokenID == kSecAttrTokenIDSecureEnclave`.
  3. Also check the app's real database key: launch the app and confirm the diagnostic (added with the app database in section 4/5) shows the key's token as the Secure Enclave.
  4. Record: device model, iOS version, test result line, and a screenshot of the diagnostic.
- [ ] Two-device CloudKit message exchange (section 5).
- [ ] Notification permission is asked when a chat is first opened, not at launch. Alerts say only "New message" (section 5).

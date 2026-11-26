# CloudKit transport (section 5)

Messages travel through each family's own iCloud. There is no server of ours. The envelopes and blobs are the same as on the loopback transport (`docs/WIRE_FORMAT.md`). This file covers where they are stored in CloudKit, the steps to turn the transport on, the deploy to Production, and the device test plan.

Code:
- Transport: `Packages/Messaging/Sources/Messaging/CloudKitTransport.swift`.
- The CloudKit calls it makes: `CloudDatabase.swift`. The real implementation is `CloudKitDatabase.swift`.
- Tests: `MessagingTests/CloudKitTransportTests.swift`. They run against an in-memory iCloud with several users (`MockCloud.swift`). That mock enforces the share rules the design relies on.

## Design

| What | Where | Who can read it |
|---|---|---|
| One record zone per conversation, `c-<32 hex>` (a hash of the conversation ID, so names don't reveal who talks to whom) | Private database of the person who sent the first message (the **owner**) | The owner, and the participants of the zone's CKShare |
| One CKShare per zone (zone-wide share) | Same zone | Participants only. `publicPermission = none`. Participants are added by iCloud user record ID and get read-write access. |
| `Envelope` records, one per message, named by message ID | The conversation's zone. Participants write through their shared database. | Owner and participants |
| `Blob` records, one per attachment, named `blob-<id>` | The conversation's zone | Owner and participants |
| `Invite` records: how a new participant learns the share URL | **Public** database | Anyone. The content is a `pgp` envelope for one recipient, filed under SHA-256 of their address, not the address itself. |

**Addresses.** A person's address is `icloud:<their iCloud user record name>` (`CKContainer.userRecordID()`). It is chosen at onboarding, which therefore needs iCloud to be signed in. It travels in "My code". Apple's user-discoverability APIs are not used: participants are added by user record ID, and the ID comes from the code scanned in person.

**First message in a chat (owner):**
1. Create the zone.
2. Share it with the other members.
3. For each member, save an `Invite`: an `Invitation {conversation, share URL}` encrypted to that member alone and signed by the owner.
4. Save the `Envelope`.

**Receiving:**
1. Fetch database changes, then zone changes, using change tokens, in both the private and the shared database.
2. Query the public database for `Invite` records whose `recipient` equals the hash of our address.
3. Copy everything fetched into a local spool (complete file protection) before saving the change token, so an interrupted fetch loses nothing.
4. The messenger then processes the spool exactly as with loopback. Invitations are accepted only from contacts. A direct chat must be between the inviter and us. Joining a share gives access to ciphertext only, and every message is still checked (`docs/WIRE_FORMAT.md`).
5. Our own records in a zone are skipped.

**Two people start the same chat at once.** Each owns a zone and joins the other's. Both read both zones, and each keeps writing to its own. Every message carries the conversation ID, so it is still one chat.

**What Apple can see:**
- With PGP on: who owns and participates in each zone, record sizes and times, the sender address on each `Envelope` record, and hashed recipients on `Invite` records. The text, names, file names and attachment bytes are ciphertext.
- With PGP off for a chat: the payload of that chat's later messages too, as the chat banner says.

**Alerts:**
- One `CKDatabaseSubscription` each on the private and shared databases.
- The fixed alert text is "New message", with no sender, chat or content, plus `content-available`.
- The push is only a hint. The app also fetches on launch, when it comes to the foreground, every 30 seconds while open, in background refresh (`BGAppRefreshTask`, at most every 15 minutes) and on pull-to-refresh.
- Alert permission is asked the first time a chat is opened (`AlertPermission`), never at launch.

**Not in build 1:**
- Deleting old records. History stays in the owner's iCloud and counts against their storage.
- Removing group members.
- Cleaning up `Invite` records. They are small ciphertext and are planned for removal after 30 days in a later build.

## Record types (Development environment)

The schema is in `CloudKit/schema.ckdb`, in the format of Apple's `cktool`. Importing it with `cktool` needs a management token from the owner's account, so it is for reference here.

| Record type | Field | Type | Index |
|---|---|---|---|
| `Envelope` | `envelope` | Bytes (up to 700 KB) | none |
| | `envelopeFile` | Asset (used instead of `envelope` for larger envelopes, up to 1 MiB) | none |
| | `sender` | String (`icloud:` address) | none |
| `Blob` | `data` | Asset | none |
| `Invite` | `recipient` | String (64 hex) | **QUERYABLE** |
| | `envelope` | Bytes | none |

- `recordName` (shown as `___recordID`) needs a **QUERYABLE** index on all three types, so they can be browsed in Console.
- In Development, CloudKit creates record types and fields the first time a build saves them ("just-in-time" schema). The device test plan below creates all three.
- The one index the app needs, `Invite.recipient`, is not created automatically. Without it the invitation query fails, so it must be added in Console, in Development, before step 3 of the device test plan.

## Turning it on (the owner, with the Apple account)

Not done in this branch: these steps register identifiers with Apple and sign builds. Until they are done, every build uses the loopback transport (`TRANSPORT_KIND = loopback` in `Config/Base.xcconfig`), CI included.

1. **Certificates, Identifiers & Profiles › Identifiers.**
   - Open (or register) the App ID `com.meltemiapps.epistoli`.
   - Enable **iCloud** with **CloudKit** support, and **Push Notifications**.
   - Under iCloud, **Edit** the container list and create or assign `iCloud.com.meltemiapps.epistoli`.
2. **Local build settings.** Create `Config/Local.xcconfig`. It is gitignored, so it never goes in the repo:
   ```
   DEVELOPMENT_TEAM = <your team ID>
   CODE_SIGN_STYLE = Automatic
   CODE_SIGN_ENTITLEMENTS = App/Epistoli.entitlements
   TRANSPORT_KIND = cloudkit
   ```
   Then run `xcodegen generate`. `App/Epistoli.entitlements` asks for CloudKit on the container, and `aps-environment = development` for Xcode builds. Xcode's automatic signing uses the production push environment for TestFlight and App Store builds.
3. **Add the `Invite.recipient` index:**
   - In CloudKit Console (https://icloud.developer.apple.com/), select the **CloudKit Database** app and choose the container at the top.
   - Make sure the **Development** environment is selected.
   - Then follow **Schema › Indexes**, plus, Record Type `Invite`, Type **QUERYABLE**, Field `recipient`, **Add**.
   - Add a QUERYABLE index on `recordName` for `Envelope`, `Blob` and `Invite` the same way.
   - If `Invite` doesn't exist yet, run device test step 3 once; the invitation query fails until the index is added. Then add the index.

## Deploying the schema to Production (the owner, in CloudKit Console)

TestFlight and App Store builds use the **Production** environment, which has its own schema. Apple's documentation says that once deployed, "you can't delete record types or fields that are already in production": only additive changes are possible later. Deploying copies record types, fields and indexes, never records.

1. Finish the device test plan in Development first, so the schema is final.
2. Sign in at https://icloud.developer.apple.com/ with an account that can edit Production (the team's Account Holder or Admin).
3. Select **CloudKit Database**, then choose `iCloud.com.meltemiapps.epistoli` in the container list at the top.
4. In the Development environment, check **Schema › Record Types**. It should show exactly `Envelope` (fields `envelope`, `envelopeFile`, `sender`), `Blob` (`data`) and `Invite` (`envelope`, `recipient`). Delete any stray test types or fields **now**: after the deploy they can't be removed.
5. Check **Schema › Indexes**: `Invite.recipient` QUERYABLE, and `recordName` QUERYABLE on all three types.
6. Check **Schema › Security Roles** for the public database. Apple's pages I could read don't document the defaults, so verify these in Console:
   - World can read `Invite`.
   - Authenticated users can create `Invite`.
   - Only the creator can write (change or delete) an `Invite`.
7. On the left, select **Deploy Schema Changes…**. Review the pending changes: three record types, their fields and their indexes. Then click **Deploy**.
8. Switch the environment selector to **Production** and confirm that the three record types and the indexes are there.

## Device test plan

The **iPhone** is the chat owner and the **iPad** the participant, on **two different Apple IDs**. Both run a Debug build from Xcode, which uses the **Development** environment. Record results, device logs and screenshots in `build/device-tests/` only. Never write an Apple ID, device name, serial number or UDID into the repo, commits or PR text.

**Before:**
- "Turning it on" is done.
- Both devices are on iOS 26, signed in to iCloud with iCloud Drive on, and have notifications allowed in Focus.
- In Console, the Development environment shows no records for either user, or it has been reset with **Reset Environment**.

| # | Step | Device | Expected |
|---|---|---|---|
| 1 | Install and launch; create a key | both | Onboarding succeeds. Settings › Your key says **Secure Enclave**. No alert prompt yet. |
| 2 | My code on the iPad, Scan with the iPhone's camera; then the other way round | both | Each shows the other as **Verified**. |
| 3 | iPhone: open the chat with the iPad's owner | iPhone | The alert permission prompt appears now, the first time a chat is opened. Allow. |
| 4 | iPhone: send "Hello from the iPhone" | iPhone | Console (iPhone's account, Development) shows a zone `c-…` in the private database with a share. The public database has one `Invite` whose `recipient` is 64 hex digits. |
| 5 | iPad: open the app | iPad | The chat appears with the message. The prompt appears when the chat is first opened. Allow. |
| 6 | iPad: reply | iPad | The iPhone shows the reply within 30 s while open, or at once on pull-to-refresh. Still one zone in Console (owned by the iPhone). |
| 7 | Lock the iPad; iPhone sends "Are you there?" | both | The iPad lock screen shows an alert saying only **New message**, with no name, chat or text. |
| 8 | Attachments: iPhone + › Photos; iPad + › Files (On My iPad); iPad + › iCloud Drive | both | Each arrives with the right name, size and "from …". It opens in Quick Look; close it by hand. |
| 9 | In Console, open an `Envelope` and a `Blob` record | — | `envelope` and `data` are unreadable binary (OpenPGP). No message text or file names appear anywhere. |
| 10 | iPhone: PGP chip › Turn PGP off; send "TLS only" | both | Both show PGP off and the banner. The iPad shows "Encrypted in transit only" under the message. In Console that envelope's body is readable JSON. Turn PGP back on. |
| 11 | iPad: Airplane Mode; iPhone sends 3 messages; iPad back online | both | All 3 arrive once, in order. |
| 12 | Force-quit the iPad app; iPhone sends one; wait 15 min without opening the iPad app | iPad | An alert arrives. Background refresh may fetch it, and opening the app shows it. No duplicates. |
| 13 | iPad (Debug): Settings › Developer › Simulate new phone; iPad shows My code; iPhone **pastes** it as text | both | The iPhone's chat shows the key-change banner, and its first send asks "Send anyway". Messages from the iPad's new key are readable after the key is accepted. Scanning the new code in person clears the banner. |
| 14 | Group: iPhone creates "Family" with the iPad (and a third Apple ID if available) | all | Every member joins from the invitation. Messages and an attachment arrive on all. |
| 15 | Sign out of iCloud on the iPad and open the app | iPad | Sending shows "Sign in to iCloud…". Nothing crashes. |
| 16 | Deploy the schema to Production (above), then install a TestFlight build on both and repeat steps 3–8 | both | The same results, in Production. |

Report the results as a table in the checkpoint report: pass/fail per step, with notes.

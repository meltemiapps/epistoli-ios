# Wire format (version 1)

How messages travel between phones. There is no server: each person's messages go to a **mailbox** that only their phone reads, through a transport. Section 4 uses the **loopback** transport (a folder on disk shared by simulators on one Mac). Section 5 adds CloudKit with the same envelopes and blobs.

Code:
- Types (pure Swift, tested on Linux): `Packages/EpistoliCore/Sources/EpistoliCore/Messages.swift`.
- Sealing, checks and storage: `Packages/Messaging/Sources/Messaging/` (`Messenger.swift`, `Transport.swift`, `ConversationStore.swift`).
- Tests: `WireFormatTests` (EpistoliCore) and `MessagingTests` (Messaging).

## Addresses and mailboxes

An address is `scheme:value` (see `docs/CONTACT_CODE.md`). It travels in "My code" and identifies a person across key changes. A new phone gets a new key, but the person keeps the address.

- `loopback:<32 lowercase hex>`: a random 128-bit mailbox name chosen at onboarding.
- `icloud:…` arrives in section 5.

The transport never derives a file name or record name from free text. It uses only a validated address or a UUID.

## Conversation IDs

| Kind | ID | Notes |
|---|---|---|
| Direct | `d:` + both addresses, sorted, joined by one space | Both phones compute the same ID, so a chat started on either side is the same chat. |
| Group | `g:` + a random UUID (lowercase) | Chosen by the creator. |

`channel` and `assistant` are reserved for v1.2 (`docs/ROADMAP.md`) and are refused by v1.

## Envelope

One envelope per message per recipient. The JSON uses sorted keys, dates as seconds since 1970, and binary data as Base64. An envelope is at most 1 MiB, because attachment bytes travel separately as blobs.

| Field | Type | Notes |
|---|---|---|
| `v` | int | `1`. Other versions are refused. |
| `id` | UUID | The message ID. Also the file or record name. |
| `from` | address | The sender. Used only to pick the key to verify with. The signed payload repeats it. |
| `mode` | `pgp` \| `signed` | See below. |
| `body` | bytes | `pgp`: an OpenPGP message. `signed`: the payload JSON. |
| `signature` | bytes | `signed` only: an OpenPGP detached signature over `body`. Must be absent in `pgp` mode. |

- **`pgp`** (the default for every chat): the payload is encrypted to every recipient's current key and signed with the sender's identity key (GopenPGP, Curve25519). The transport and the cloud provider see only the envelope fields above, never the chat, the text, names or file names.
- **`signed`** (PGP turned off for the chat): the payload is in the clear. It is protected in transit by TLS (section 5) and stored by the user's cloud provider, who could technically read it. The chat banner says exactly that. It is still signed, so nobody can forge or alter a message.

## Payload

The inside of the envelope: decrypted in `pgp` mode, verified in `signed` mode.

| Field | Type | Notes |
|---|---|---|
| `v` | int | `1` |
| `id` | UUID | Must equal the envelope `id`. |
| `from` | address | Must equal the envelope `from`. |
| `conversation` | conversation ID | |
| `group` | object or absent | Groups only: `{title, members: [{address, name, publicKey}]}`, including the sender. |
| `lamport` | uint64 | See Ordering. |
| `sentAt` | date | The sender's clock. Display only. |
| `content` | object | One of the content types below. |

Content types, by `type`:
- `text`: `{text}`.
- `attachment`: `{attachment: {blob, name, mime, size, source, blobSHA256}}`. `source` is `photos`, `files` or `iCloudDrive`. `size` is the plaintext size.
- `pgpSetting`: `{on}`. Someone turned PGP on or off for the chat. The newest setting by Lamport counter applies on every phone. These notices are always sent in `pgp` mode.

Unknown content types are refused, so that a newer app can't be misread by an older one.

## Attachments (blobs)

1. The sender reads the file on the phone, up to 25 MiB.
2. In `pgp` mode the sender encrypts and signs it to the same recipients as the message. In `signed` mode the bytes are stored as they are.
3. The sender stores the result as one blob named by a new UUID, then sends a message whose `attachment` names that blob and gives the SHA-256 of the stored blob.
4. The recipient fetches the blob and checks the SHA-256. In `pgp` mode the recipient then decrypts and verifies the sender's signature. The plaintext size must equal `size`.
5. Received attachments are kept only inside the SQLCipher database. Quick Look gets a temporary copy, with complete file protection, which is deleted when the preview closes.

The signed payload carries the hash, so in `signed` mode an altered blob is detected too. If a blob hasn't arrived yet, the envelope waits in the mailbox and is retried.

## Receiving: checks, in order

1. The envelope decodes, its version is 1, it is at most 1 MiB, and its ID matches the file name.
2. A message ID already stored is a duplicate. The envelope is removed and nothing changes.
3. **`from` must be one of our contacts.** Otherwise the envelope waits in the mailbox until we add that person by their code. Nobody can message us without being added first.
4. Decrypt and verify (`pgp`), or verify (`signed`), against the contact's **current** key. A message signed by any other key, including a key the contact used before a key change, fails here.
5. The payload's `v`, `id` and `from` match the envelope.
6. The conversation fits the sender:
   - Direct: the ID's two addresses are exactly us and the sender.
   - Group, new: the member list holds us and the sender, has no duplicates, and has at most 32 people. The group is created with that title and those members.
   - Group, known: the sender must already be a member. Membership is fixed at creation in v1, and later member lists are ignored.
7. Content checks: attachments as described above. An empty text is refused.

Envelopes that fail checks 1 and 4 to 7 are moved to the mailbox's `rejected` folder. After a contact's key changes (a new code is accepted), rejected envelopes are retried once more, so messages from their new phone appear.

### Group members we haven't met

A group's member list includes each member's public key, so members who never exchanged codes can still read and write to each other. Our phone adds such members as **Unverified** contacts (key source `receivedOtherwise`), exactly as if their code had been pasted. **A group can never change the key of someone who is already our contact.** Their key from the list is ignored.

## Key changes

When a contact's key changes and the new key wasn't scanned in person (`docs/CONTACT_CODE.md`), every chat with them shows a banner that can't be dismissed: "Maria's key changed and hasn't been checked in person". The first send in that chat asks for confirmation ("Send anyway"). Only scanning their code with the camera clears the banner.

## Ordering

Every chat keeps a Lamport counter, the highest value seen in that chat:
- Sending: the counter goes up by one, and the message carries the new value.
- Receiving: the counter becomes max(local, received).

Messages are shown sorted by `(lamport, sender address, id)`. Every phone sorts the same set of messages the same way, whatever order they arrived in. Two messages written at the same time get equal counters, and the sender address breaks the tie. `sentAt` is shown but never used for ordering, because phone clocks differ.

## Loopback layout (section 4)

```
<root>/v1/
  tmp/                                 files being written (renamed into place when complete)
  blobs/<uuid>                         attachment blobs
  mailboxes/<32 hex>/<uuid>.json       envelopes waiting for that address
  mailboxes/<32 hex>/rejected/         envelopes that failed their checks
```

- Writers always write to `tmp/` and then rename, so a reader never sees half a file.
- The receiver polls its mailbox every second, processes each envelope, and deletes it.
- Simulators share `<root>` with the launch argument `-loopback.root <absolute path>` (`scripts/checkpoint_d.sh`). Without it, the root is the app's own Application Support folder, and messages stay on that phone.
- The loopback transport has no TLS, no access control and no blob clean-up. It exists for development only. Section 5 replaces it with CloudKit: one CKShare per conversation, with a push subscription used only as a hint to fetch.

# FLACtastic Sync Protocol v1.0

How two FLACtastic instances copy a music library between each other over a
local network.

This document is the contract. The macOS implementation under
`Sources/flactastic/Sync/` is the reference, and the iOS app implements the
same wire format from a separate codebase. A future Linux or Windows port
should be able to work from this document alone.

**Any change to a value in this document is a protocol change.** Bump
`SyncProtocol.version` and update both repos.

---

## 1. Design constraints

- **Local network only.** Nothing traverses a router, and there is no server or
  account anywhere in the design.
- **The user's files are the thing at risk.** The device that *receives* decides
  what is safe to accept, and never acts on a plan the sender computed.
- **No silent merges.** When two devices disagree, the incoming copy wins — and
  the user is shown exactly what will be replaced before it happens.
- **Nothing personal crosses the wire.** Listening history, settings, and
  credentials are explicitly out of scope. Audio files and playlists are in.

---

## 2. Discovery

Bonjour service type `_flactastic._tcp` in the `local.` domain.

Advertising is **opt-in and temporary**: it starts when the user opens the sync
UI, stops when they leave it, and stops on an idle timeout regardless.

### TXT record

A TXT record is broadcast unencrypted to everyone on the network. These five
keys are the complete set; adding anything is a protocol change.

| Key | Meaning | Example |
|-----|---------|---------|
| `v`  | Protocol version, `major.minor` | `1.0` |
| `id` | Device ID — a **random UUID**, not derived from hardware, hostname, or user | `9F1C…` |
| `n`  | Display name, ≤ 63 UTF-8 bytes | `Studio Mac` |
| `k`  | Device kind: `mac`, `iPhone`, `iPad`, `other` | `mac` |
| `p`  | `1` while a pairing code is on screen, else `0` | `0` |

A record missing `id` or `v`, or carrying an unparseable value for either, is
ignored rather than reported — noise on a shared service type is ordinary.

**Reading a peer's name is not trusting it.** `n` is attacker-controlled: strip
control characters and the bidirectional-override scalars (`U+202A…U+202E`,
`U+2066…U+2069`) before display, clamp the length, and prefer a name recorded at
pairing time over an advertised one.

### Platform requirements

- **iOS 14+ / macOS 15+** require `NSLocalNetworkUsageDescription` **and** an
  `NSBonjourServices` array containing `_flactastic._tcp`. Without them
  discovery returns nothing and the listener fails, *silently* — indistinguishable
  from "nobody else is running FLACtastic".

---

## 3. Transport

TLS over TCP, authenticated with **pre-shared keys** (`NWProtocolTLS` +
`sec_protocol_options_add_pre_shared_key`).

- Ciphersuite: `TLS_AES_128_GCM_SHA256`. Minimum version TLS 1.2.
- A **listener registers one PSK per paired peer**, with PSK identity
  `flactastic-peer-v1:<that peer's device UUID>`.
- A **client** presents its *own* device ID as the identity, with the key the
  two agreed at pairing.

This is what makes revocation absolute: deleting a peer's key removes it from
the listener's PSK set, so its handshake cannot complete at all.

TLS alone does **not** tell the listener *which* PSK a connection used —
Network.framework completes the handshake with whichever registered key
matches and does not report it. While a code is on screen the public pairing
PSK (below) is registered alongside the peer keys, so a completed handshake
proves only "paired peer **or** anyone". The channel binding below closes that.

### Channel binding

A sync opens with `hello { isPaired: true, proof }`, where:

```
exporter = TLS-Exporter(label: "EXPORTER-flactastic-channel-v1", context: none, length: 32)
proof    = HMAC-SHA256(longTermKey, "flactastic-hello-v1" ‖ 0x00 ‖ deviceID (16 raw bytes) ‖ exporter)
```

The responder looks up the long-term key for `hello.deviceID`, derives the same
exporter from its end of the session, and verifies `proof` in constant time
**before** sending anything else, including a version error. On failure it
sends `protocolError(notPaired)` and closes. The exporter is unique to the
session, so a proof cannot be replayed, and it is bound to the claimed device
ID, so it cannot be presented under another identity.

### The pairing channel

First contact has no shared secret, so it uses a **fixed, publicly known** PSK
with identity `flactastic-pairing-v1` and key:

```
SHA256("flactastic-public-pairing-key-v1")
```

This is encryption against a passive eavesdropper and **nothing else**. It is
not authentication; an active attacker completes it as easily as a real peer.
All security for that phase comes from the pairing handshake carried inside
(§4), which is designed for an unauthenticated channel.

**Only pairing messages may cross a pairing-PSK connection.**

### Framing

Every message on the connection is:

```
┌────────┬──────────────────┬───────────────┐
│ type   │ length           │ payload       │
│ u8     │ u32 big-endian   │ length bytes  │
└────────┴──────────────────┴───────────────┘
```

| type | meaning | max payload |
|------|---------|-------------|
| `1` | Control — a JSON `WireMessage` (§5) | 8 MiB |
| `2` | File chunk — raw bytes of the transfer in progress | 1 MiB |

A length prefix over the limit for its type is a protocol error: **reject on the
header alone, before buffering the payload it claims.** An unknown type is also
fatal — the stream position is unknowable from that point on.

---

## 4. Pairing

One device shows an 8-digit code; the other types it.

### Why it is built this way

Eight digits is not much entropy. A plain Diffie-Hellman exchange authenticated
by a short code is breakable: an attacker who sees both public keys before
choosing its own can grind offline for the code.

The fix is that the **host commits to its key before it sees the guest's**. An
attacker in the middle must therefore commit blind, and cannot tune the exchange
to match a guessed code. It gets exactly **one online guess**, and a wrong guess
destroys the code.

### Sequence

The dialler always speaks first, for a sync and for pairing alike — that is how
the listener tells the two apart before it says anything. A guest opens with
`hello { isPaired: false }`; the host answers it with `pairCommit`. (v1.0 as
first written had the guest wait for `pairCommit` and the host wait for the
guest, and every pairing attempt deadlocked.)

```
guest → hello         { version, deviceID, displayName, deviceKind, isPaired: false }
host  → pairCommit    { commitment: SHA256(hostPub ‖ hostNonce) }
guest → pairGuestKey  { publicKey: guestPub }
host  → pairReveal    { publicKey: hostPub, nonce: hostNonce }
        guest verifies the commitment; mismatch → abort
guest → pairConfirm   { mac: HMAC(k, "guest" ‖ 0x00 ‖ code), deviceID, displayName, deviceKind }
        host verifies; mismatch → abort
host  → pairConfirm   { mac: HMAC(k, "host"  ‖ 0x00 ‖ code), deviceID, displayName, deviceKind }
        guest verifies; mismatch → abort
        guest saves the key; failure → pairResult { success: false, failureReason: "storage-failed" }
guest → pairResult    { success: true }
        host saves the key
host  → pairResult    { success: true }                            [ack]
```

Each side saves before sending its final message, and a guest that does not
receive the host's ack deletes the key it saved. Without the ack, a Keychain
failure on the host left the guest believing it was paired with a device that
refused every sync. A save failure on either side is reported with
`failureReason: "storage-failed"` so the other side can say so rather than
blaming the code.

Curve25519 (X25519) key agreement. Nonce is 32 random bytes.

If no code is live when the guest's `hello` arrives, the host sends
`protocolError(pairingClosed)` and closes; that does not count as a failure,
since there was nothing to guess. Any other failure on the host is reported to
the guest as `pairResult { success: false }` before the connection closes.

### Derivation

```
transcript = len32(commitment) ‖ commitment
           ‖ len32(hostPub)    ‖ hostPub
           ‖ len32(hostNonce)  ‖ hostNonce
           ‖ len32(guestPub)   ‖ guestPub

k          = HKDF-SHA256(sharedSecret, salt: transcript,
                         info: "flactastic-pair-v1",   len: 32)

longTermKey = HKDF-SHA256(k,           salt: transcript,
                          info: "flactastic-session-v1", len: 32)
```

Length prefixes are load-bearing: without them an attacker could shift bytes
between adjacent fields and produce an identical transcript from a different
handshake.

The role label in the MAC (`"host"` / `"guest"`, NUL-separated from the code) is
also load-bearing: without it, one side's confirmation could be reflected back
as the other's, proving nothing but passing the check.

### Policy

Cryptography limits an attacker to one guess per handshake. These rules limit
how many handshakes they get:

- Codes are **8 digits**, uniformly random. Use rejection sampling, not `% 10` —
  modulo bias would favour low digits.
- A code is **single-use** and expires after **120 seconds**.
- **Every** failure burns the code, whatever caused it — a typo, a tampered
  message, a dropped connection.
- **3** consecutive failures lock the listener out for **60 seconds**.
- When a code is withdrawn for **any** reason — expiry included — the pairing
  PSK comes off the listener and the TXT `p` flag returns to `0`. A device must
  never advertise, or accept, pairing with no code on screen.
- Codes never persist across app launches.
- A malformed code is rejected **locally**, before connecting, so a typo does
  not consume one of the host's attempts.

The long-term key goes in the Keychain, `WhenUnlockedThisDeviceOnly`. **There is
no plaintext fallback** — if the Keychain is unavailable, pairing fails loudly
rather than quietly downgrading every future connection.

Failure messages shown to the user must not reveal *which* step failed or how
close a guess was.

---

## 5. Control messages

JSON, UTF-8, with an explicit discriminator:

```json
{ "t": "<tag>", "d": { … } }
```

Encoding rules, all stated because Foundation's defaults have changed between
OS versions:

- Dates: **ISO-8601 with fractional seconds** (`2026-09-08T17:04:01.687Z`).
  Whole-second precision walks playlist timestamps backwards on every sync hop.
- `Data`: base64.
- Object keys: **sorted**, so equal values encode to identical bytes.

An unknown `t` is answered with `protocolError(unsupportedMessage)` and the
connection closes. Never guess.

### Tags

| Tag | Direction | Payload |
|-----|-----------|---------|
| `hello` / `helloAck` | both | `version`, `deviceID`, `displayName`, `deviceKind`, `isPaired`, `proof?` (hello with `isPaired: true` only — §3) |
| `pairCommit` | host → guest | `commitment` |
| `pairGuestKey` | guest → host | `publicKey` |
| `pairReveal` | host → guest | `publicKey`, `nonce` |
| `pairConfirm` | both | `mac`, `deviceID`, `displayName`, `deviceKind` |
| `pairResult` | both (guest's result, then host's ack) | `success`, `failureReason?` |
| `syncRequest` | both | `direction`, `filter`, `manifest` |
| `planProposal` | receiver | `plan`, `receiverFreeBytes?` |
| `planDecision` | initiator | `planHash`, `approved`, `selection?` (§7) |
| `fileStart` | sender | `trackID`, `relativePath`, `fileSize`, `contentHash`, `tagFingerprint` |
| `fileAccept` | receiver | `trackID`, `resumeOffset`, `skip` |
| `fileEnd` | sender | `trackID` |
| `playlists` | sender | `playlists` — full playlist objects |
| `syncComplete` | sender | `tracksTransferred`, `playlistsTransferred`, `bytesTransferred` |
| `cancel` | both | `reason` |
| `protocolError` | both | `code`, `message` |

Error codes: `incompatibleVersion`, `notPaired`, `pairingClosed`,
`pairingFailed`, `rateLimited`, `unsupportedMessage`, `unexpectedMessage`,
`invalidPath`, `hashMismatch`, `sizeExceeded`, `insufficientStorage`,
`planStale`, `internalFailure`.

---

## 6. Identity and the manifest

### Track identity

Every audio file carries a UUID in the extended attribute
**`com.flactastic.trackID`**, which survives moves, renames, and reorganisation
on both APFS and HFS+. This is the primary key for the whole protocol.

Matching is two-tier:

1. **`trackID`** — the normal case.
2. **`contentHash`** (SHA-256 of the whole file) — the fallback. Extended
   attributes are lost crossing FAT/exFAT volumes, zip archives, and some cloud
   providers, and two libraries can import the same file independently. Without
   this tier, every such file would transfer again on every single sync.

After receiving a file, the receiver **adopts the sender's `trackID`**, so the
next run matches on identity instead of re-hashing.

### `TrackManifestEntry`

| Field | Notes |
|-------|-------|
| `trackID` | The xattr UUID |
| `relativePath` | Relative to the sender's library root. **Untrusted** — see §8 |
| `fileSize` | Bytes; must be ≤ 2 GiB |
| `contentHash` | Lowercase hex SHA-256 of the whole file |
| `format` | `flac`, `mp3`, `wav`, `aiff`, `alac`, `aac` |
| `tagFingerprint` | See below |
| `title`, `artist`, `album` | Display only; **never** used for matching |
| `albumArtist?` | Display only. Optional; absent means untagged. The confirmation checklist files each album (title + folder) under its album artist, else its most-credited track artist, so tracks crediting featured artists stay with their album |

### `tagFingerprint`

SHA-256 over these fields, in this order, joined by `U+001F` (unit separator —
it cannot occur in a tag, so no value can forge a field boundary):

```
title, artist, albumArtist, album, trackNumber,
genre, secondaryGenres (sorted, comma-joined), year,
isCompilation ("1"/"0"),
"mix"  ← only when isMixCompilation is true
```

Normalisation, so cosmetic differences don't manufacture conflicts the user
then learns to click through: NFC, trimmed of surrounding whitespace, `null`
treated as empty string.

> **Extending this is the one thing most likely to break cross-platform sync.**
> A new field must be appended **at the end** *and* contribute **nothing in its
> default state**. `isMixCompilation` is macOS-only — iOS has no such field and
> sends nothing — so it appends `"mix"` only when true. Encoding `"0"` when
> false would make a Mac and an iPhone disagree on every track's fingerprint,
> turning an entire cross-platform library into phantom conflicts.

### `PlaylistManifestEntry`

`id`, `name`, `dateCreated`, `entryCount`, and a content hash over
`name` plus the ordered `trackID|relativePath` pairs.

Order is included — a reordered playlist is a different playlist to the person
who reordered it. `PlaylistEntry.id` is **excluded**: it is local UI bookkeeping
and differs between two devices holding the same playlist, so including it would
make every playlist a permanent conflict.

---

## 7. A sync run

```
initiator → hello(proof)             responder → verifies proof (§3)
                                     responder → helloAck
                                     (major version must match exactly)

initiator → syncRequest(direction, filter, its manifest)
responder → syncRequest(inverted,  filter, its manifest)

── both sides now hold both manifests and both filters ──
── each computes the plan independently ──

initiator shows the plan to the user, who may untick parts of it
initiator → planDecision(planHash, approved, selection?)
responder → compares planHash against its own computation
            mismatch → protocolError(planStale), abort
── both sides narrow the plan to `selection` (absent = all of it) ──

── files flow in the agreed direction, then playlists ──
sender    → syncComplete
```

### Selection

`selection` is `{ trackIDs?, playlistIDs? }` — explicit IDs of plan items,
where an absent set means "all of that kind". `planHash` is always the hash of
the **full** plan, so both sides prove they started from the same list; each
then narrows it with the same rule: keep an item if its ID is in the set, drop
IDs the plan does not contain. A selection can therefore only remove work. The
receiver enforces the narrowed plan for tracks *and* playlists, and checks free
space and `maxTotalTransferBytes` against the narrowed plan, so choosing the
part of a library that fits is possible. The responder waits up to 30 minutes
for the decision, since a person is working through a checklist.

The responder sends `helloAck` **before** building its manifest. Building one
hashes every file the filter admits, which on a first sync of a large library
takes minutes; the initiator waits up to 30 minutes for the responder's
`syncRequest` for that reason.

`direction` is always expressed **from the initiator's point of view**:
`push` = initiator sends, `pull` = initiator receives. One direction per run;
bi-directional convergence is two runs.

### Why both sides compute the plan

The receiver must never act on a plan the sender handed it. But the user is
sitting at the initiator, so the plan has to be shown there. `SyncDiff` is a
pure function of two manifests and a filter, so both sides derive the same plan
independently and exchange only its hash. A mismatch means a library changed
while the confirmation sheet was open, and the run is abandoned rather than
applying an approval the user never actually gave.

The plan is computed from the **receiver's** filter, which both sides know
because filters are exchanged alongside manifests.

### The diff

For each incoming track:

- Known `trackID`, and `contentHash` or `tagFingerprint` differs → **conflict**
  (transfer + warn the user).
- Known `trackID`, everything matches → skip.
- Unknown `trackID` but a known `contentHash` → skip (adopt the ID afterwards).
- Otherwise → **new** (transfer).

For each incoming playlist: unknown `id` → new; known `id` with a different
content hash or name → conflict.

### `planHash`

Sorted lines, newline-joined, SHA-256:

```
<direction>
n:<trackID>:<contentHash>      for each new track
c:<trackID>:<contentHash>      for each conflicting track
p:<playlistID>:<contentHash>   for each new playlist
q:<playlistID>:<contentHash>   for each conflicting playlist
```

---

## 8. File transfer

Per file:

```
sender   → fileStart  { trackID, relativePath, fileSize, contentHash, tagFingerprint }
receiver → fileAccept { trackID, resumeOffset, skip }
             skip: true          → nothing sent, move to the next file
             resumeOffset: N > 0 → sender seeks to N
sender   → [type 2 chunks, ≤ 1 MiB each, in order]
sender   → fileEnd { trackID }
```

The receiver:

1. Stages into `<libraryRoot>/.flactastic/incoming/<trackID>.part`.
2. Aborts the moment received bytes exceed `fileSize` — a peer must not be able
   to write until the disk fills.
3. Verifies SHA-256 over the completed file.
4. Installs with an atomic replace, so a reader sees the old file or the new
   one, never a gap.
5. Writes the sender's `trackID` to the destination's xattr.

A file that **fails its digest is deleted**, not kept for a later resume — the
bytes are known-bad and resuming on top of them would only reproduce the
failure.

### Resume

The `.part` file *is* the resume record: its length is `resumeOffset`. This is
why the digest is checked only at the end — a partial file cannot be verified,
so resuming is a bet on the bytes already on disk, settled by the whole-file
hash before anything enters the library. A `.part` **longer** than the declared
size belongs to a different version of the file and is discarded rather than
spliced. Partials older than 7 days are swept.

### Path safety

`relativePath` is the one field a peer controls that decides **where we write**,
and on macOS FLACtastic is unsandboxed. Treat it as hostile.

Reject outright — never repair:

- `..` in any position, and any component made **only** of dots (`...`, `....`).
  Repairing invites the `....//` bypass, where stripping one `../` leaves
  another behind.
- Absolute paths: leading `/`, `\`, `~`, or a `C:` drive prefix.
- Empty components (`//`), `.` components, null bytes.
- Components > 255 UTF-8 bytes, depth > 32, total > 3072 bytes.
- For tracks, any extension not in the recognised audio set. An unsandboxed app
  scanning a folder a peer can write `.dylib` into is a code-execution
  primitive.

Then:

1. **Normalise to NFC before comparing** — `..` has decomposed spellings.
2. Check dot-only components on the **raw** component, *before* any sanitising
   step that might rewrite a leading dot and hide it.
3. Sanitise each surviving component the same way a local import would.
4. Resolve under the library root and **re-check containment after symlink
   resolution** — a path built only from safe components still escapes if an
   existing intermediate directory is a symlink pointing elsewhere.
5. Compare **path components**, not string prefixes: `/Library Backup` is not
   inside `/Library`.

A receiver may place the file wherever it likes — mirroring the sender's layout
is a default, not an obligation. macOS re-derives the path through the user's
Organizer profile when one is active.

---

## 9. Filters

Applied by the **sender** when building its manifest, and again by the
**receiver** on arrival. The second pass is not redundant: a peer that ignores
the agreed filter is buggy or hostile, and either way must not be able to fill
the user's disk.

| Field | Meaning |
|-------|---------|
| `excludedFormats` | Formats to leave out |
| `excludedArtistKeys` | Artists, keyed diacritic- and case-insensitively |
| `maxFileSizeBytes` | Skip any file larger than this |
| `includePlaylists` | Whether playlists travel at all |
| `playlistIDAllowlist` | `null` = all |
| `maxTotalTransferBytes` | Ceiling for one run |

Every field decodes with a default, so a filter written by an older build — or
sent by a peer on an older minor version — keeps loading.

A receiver must also refuse a run it cannot finish, before transferring
anything: check free space with 500 MB of headroom. This matters most on iOS,
where the library is the app container and running out of space mid-run leaves a
half-synced library on a device with no room to fix it.

---

## 10. Limits

| Limit | Value |
|-------|-------|
| Control frame | 8 MiB |
| File chunk | 1 MiB |
| Single file | 2 GiB |
| Path component | 255 UTF-8 bytes |
| Path depth | 32 |
| Whole path | 3072 bytes |
| TXT value | 63 bytes |
| Pairing code | 8 digits, 120 s, single use |
| Pairing lockout | 3 failures → 60 s |
| Connection/handshake timeout | 20 s |
| Idle read timeout | 60 s |
| Pairing step timeout | 30 s |
| Wait for responder's manifest | 30 min |
| Wait for the plan decision | 30 min |

A handshake timeout is mandatory, not optional polish: Network.framework treats
an unreachable or wrong-key peer as a *path* problem and retries indefinitely,
so without a bound the UI hangs forever instead of reporting a failure.

A timeout must also actually *end* the wait. Racing a receive against a sleep
in a Swift task group is only correct if the receive responds to cancellation:
the group waits for every child before returning, so a continuation that
ignores cancellation turns the timeout back into a hang.

---

## 11. Conformance checklist

A new implementation should be able to answer yes to all of these:

- [ ] Advertising is off by default and stops on an idle timeout.
- [ ] The TXT record contains only `v`, `id`, `n`, `k`, `p`, and `id` is random.
- [ ] Peer display names are stripped of control and bidi-override characters.
- [ ] Unpaired connections can send *only* pairing messages.
- [ ] A sync `hello` is rejected unless its channel-binding `proof` verifies.
- [ ] The dialler speaks first; a pairing guest opens with `hello(isPaired: false)`.
- [ ] Pairing codes are single-use, expire, and every failure burns one.
- [ ] Long-term keys are in the platform keychain, never in plaintext storage.
- [ ] A revoked peer cannot complete the TLS handshake.
- [ ] Control-frame and chunk length prefixes are validated on the header alone.
- [ ] Every received path passes §8 before touching the filesystem.
- [ ] Files are staged, digest-verified, then atomically installed.
- [ ] The receiver recomputes the plan and refuses a mismatched `planHash`.
- [ ] A `selection` only narrows the plan; the receiver refuses anything outside the narrowed plan.
- [ ] Filters are enforced on receipt, not only on send.
- [ ] `tagFingerprint` matches §6 exactly, including absent-equals-default.
- [ ] Dates encode with fractional seconds; JSON keys are sorted.

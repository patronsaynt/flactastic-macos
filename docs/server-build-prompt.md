# Prompt: build FLACtastic Server (Debian)

Paste everything below the line into Claude Code (Opus 5.5), started in a new, empty sibling directory or a `server/` folder of this repo.

---

You are building **FLACtastic Server**: a self-hosted, multi-user lossless music server for Debian Linux that FLACtastic clients (macOS, iOS, Windows, Linux) will stream from and sync to. The macOS client does not support a server yet. The server comes first, and the macOS client gets built against it next. Your API contract is therefore a deliverable as important as the code.

The FLACtastic macOS app is the reference for everything. Read it before you design anything. It is at `/Users/angelo/computer stuff/Programming/Projects/FLACtastic/flactastic_project/flactastic`, on its current branch. Do not modify it.

## Operating rules

- **Write the least code that works.** Every line must earn its place. No speculative abstractions, no config knobs nobody asked for, no dead code, no comments that restate the code. Prefer the standard library and one or two well-chosen dependencies over a framework. A dependency needs a one-line justification.
- **Ask before you build.** Use the AskUserQuestion tool, 1–4 questions per round, recommended option first. Don't ask what the code or docs already answer. After the interview, present a one-page design for approval. Write no server code until it's approved.
- **Never touch the git index.** No `git add`, `git rm`, `--cached`, or commits unless I ask. Delete files with plain `rm`. Leave changes uncommitted.
- **Copy stays brief and natural.** One-line subtitles, no explaining the app, no invented taglines. This applies to the web UI, CLI help and the installer.
- If `version.txt` convention matters for the server's own version, keep the `beta-N` prefix style.

## Phase 0: study the reference (no questions yet)

Read, in this order:

1. `docs/sync-protocol-v1.md`, the LAN peer-to-peer sync contract: Bonjour discovery, TLS-PSK, pairing, manifests, diff, resumable file transfer, filters, limits.
2. `Sources/flactastic/Sync/` (`Protocol/`, `Engine/`, `Security/`), especially `Manifest`, `SyncDiff`, `SyncFilter`, `PathSanitizer`, `ContentHasher`, `FileTransfer`.
3. `Sources/flactastic/Library/`: `Track`, `AudioFileFormat`, `LibraryScanner`, `MultiValueParser`, `GenreResolver`, `MetadataWriter`, `Playlist`.
4. `Sources/flactastic/Persistence/LibraryIdentity.swift`, `PlaylistStore`, `TrackIDStore`.
5. `PRODUCT.md`, `DESIGN.md`, `README.md`, `Package.swift` (TagLib is the tag engine) and `Scripts/` (current packaging style).

Facts you must carry forward:

- Formats: flac, mp3, wav, aiff, alac, aac (m4a is ambiguous between alac and aac).
- Track identity is a UUID in the xattr `com.flactastic.trackID`. The fallback is a SHA-256 `contentHash`. `tagFingerprint` uses `U+001F` joining and appends fields at the end only, contributing nothing in a default state. **Server fingerprints must be byte-identical to the Mac's.**
- A library is a folder with `.flactastic/library.json` holding a stable library ID.
- Multi-value tags (ARTISTS, GENRE, secondary genres) have one parser that does all the splitting.
- Listening history, settings and credentials never cross the wire.
- Peer-supplied relative paths are hostile. Reject, never repair, and re-check containment after symlink resolution.
- v1 sync is LAN-only by design and has no server or account. A server breaks that assumption, so decide deliberately which v1 ideas carry over (manifest, diff semantics, resume, filters, the receiver-confirms principle) and which are replaced (PSK transport, Bonjour-only discovery).

## Phase 1: the interview

Ask until the design is settled. Cover at least these topics, adding your own where the code raises them:

1. **Language and runtime.** Compare Swift on Linux, Go and Rust against these criteria: reuse of the Mac's parsers and fingerprint logic, TagLib availability on Debian, single-binary installs, memory use, and my ability to maintain it. Give a recommendation.
2. **Hardware target.** Raspberry Pi class, a NAS, or a beefy box? Which Debian releases (12, 13) and architectures (amd64, arm64)?
3. **Network reach.** LAN only, or also reachable from the internet? If remote, choose between built-in TLS with ACME, a documented reverse-proxy setup, or a tunnel. How are self-signed certs pinned? How should TLS and the client's trust of the server work given v1's pairing model?
4. **Accounts and auth.** Admin vs user roles. Per-device, revocable tokens obtained through a pairing code (as v1) or username/password. Password hashing, token lifetime, rate limiting and lockout.
5. **Storage.** Per-user library root on local disk or a mounted share (NFS/SMB). What happens when the mount disappears, where does index data live (never on the share, as with `LibraryIdentity`), and are quotas needed?
6. **Library ownership.** Are libraries read-only to the server (the server scans what's there), or can clients upload and add music to it? Can clients edit tags or playlists, and if so what is the conflict policy? v1 says the incoming copy wins after the user sees what will be replaced.
7. **Streaming.** Lossless means original bytes, with no transcoding by default. Confirm HTTP range, ETag and conditional requests, `sendfile` where possible, and the MIME types iOS `AVPlayer` and desktop players require. Do I want an optional lossy transcode for bad connections, or none? Artwork sizes, and what to do about gapless and CUE-based mix tracks.
8. **Offline copies (client-initiated).** The client requests files from its user's library and keeps copies locally. The server never pushes. Propose a design, for example a manifest and diff endpoint, per-request selections (whole library, selected albums, playlists, v1-style filters) and resumable ranged downloads verified by `contentHash`. Should the server also expose a lightweight "library changed" signal so clients know when to re-check? Does the server keep any per-device sync state, or is the client the sole source of truth?
9. **Per-user data.** Should playlists live on the server? Listening history (v1 explicitly keeps it off the wire)? Is a server-side "On this day" or stats feature wanted, or is it out of scope?
10. **Discovery.** Advertise via mDNS (avahi) so clients find the server? Match `_flactastic._tcp` or use a new type? Which TXT keys, under v1's rule that the TXT record is public and minimal?
11. **Management surface.** The CLI is mandatory. Argue for or against a web UI. If you think it's worth it, propose a minimal admin-only one embedded in the binary, with no external CDN, no JS build chain, strict CSP and CSRF protection, covering users, devices, scan status and logs. Let me decide.
12. **Operations.** Metrics and logging (journald only?), backups of the index, the upgrade path, and index rebuild from the music folder as the always-safe recovery.
13. **Packaging.** Installer script only, or also a `.deb` and a GitHub release workflow? The mac repo pins actions to commit SHAs, so keep that practice.

## Phase 2: design and contract

Produce, and wait for my approval of:

- A one-page architecture summary: components, data model (SQLite WAL index per user), threat model, dependency list with justifications.
- `docs/server-protocol-v2.md` plus an OpenAPI file: endpoints for pairing/auth, library browse and search, track/artwork streaming, manifest and diff, file download for offline copies, playlists, and errors (plus a change signal if approved). State limits, encoding rules and versioning explicitly, in the style of `sync-protocol-v1.md`. This is what the macOS client will be built from, so write it to stand alone.
- Fingerprint and manifest **test vectors** generated from the Mac code, with a test that fails the build if the server ever disagrees with them.

## Phase 3: build

- Layout: a self-contained `server/` tree (or the sibling directory I name) with its own build, tests and docs.
- Multi-user from the start: one library per user, strict isolation. No path, ID or token from one user may reach another's files. Use tests to prove it.
- Scanning: incremental, using inotify where the root is local and polling where it is a network mount. It must be safe on a half-written file, tolerate unreadable files, and never write into a library unless the approved design allows it.
- Streaming: no full-file buffering, bounded memory per connection, correct partial-content semantics, and a fast path for the common FLAC case.
- Run as an unprivileged system user. The systemd unit is hardened (`ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp`, syscall and capability limits, `ReadWritePaths` only for the data and library roots).
- Tests are written alongside code: unit tests for parsers and path safety, integration tests against a small fixture library (include FLAC with multi-value tags, mp3, and an m4a of each codec), and a multi-user isolation suite.
- Work independent pieces in parallel with subagents (for example installer, protocol doc, scanner) once the design is approved. Keep their file sets disjoint.

## Phase 4: the installer

Ship `install.sh`, which feels polished and is correct first:

- `set -Eeuo pipefail`, `shellcheck` clean, POSIX-safe where cheap, idempotent, and safe to re-run as an upgrade. Include `--uninstall` and `--purge`, and make purge ask before touching any music.
- A clear TUI with colour, steps, spinners and a final summary that degrades cleanly when there's no TTY or `NO_COLOR` is set. Support `--yes` plus flags and env vars for unattended installs.
- It checks root, Debian release, architecture and free space, then installs dependencies via apt, creates the service user and directories, installs the binary after verifying its SHA-256, installs and enables the hardened unit, offers a firewall rule (ufw, only if present), and runs a self-test against the live service.
- It walks through creating the first admin and the first user's library path (local or mounted share, with a mount check), and ends by printing the address and a one-time pairing code or credentials. It never logs a secret to disk.
- It must be honest and defensive about `curl | bash`: document the safer download-then-run path, and verify what it downloads.

## Phase 5: the review pass (after everything works)

Do these as three separate passes and report findings for each, fixing what you find:

1. **Security.** Threat-model review against the design. Cover auth bypass, cross-user access, path traversal and symlink escapes, token handling, timing attacks, request size and rate limits, TLS settings, SQL and header injection, the web UI (XSS, CSRF, CSP) if one exists, systemd sandbox escape, and installer injection or TOCTOU issues. Fuzz the path sanitizer, range parser and tag readers. Run the race detector or sanitizers your language offers.
2. **Performance.** Load-test with many concurrent range streams, a large library scan (100k+ tracks, local and over NFS) and a cold start. Measure CPU, RSS, open file descriptors and time to first byte. Fix only measured problems, and record before and after numbers.
3. **Bloat.** Remove unused dependencies, dead code, duplicate helpers and needless options. Report the line count and binary size before and after.

## Deliverables

The server source, tests, the stand-alone protocol doc and OpenAPI file, test vectors, `install.sh`, the systemd unit, a short `README` covering install, first run and CLI usage, and a `REVIEW.md` summarising the three passes with numbers. Finish with a brief list of what the macOS client needs to implement, in order.

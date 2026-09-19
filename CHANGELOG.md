# Changelog

**Created:** 2026-09-01 14:25:15 +0500  
**Updated:** 2026-09-19 16:38:40 +0300  
**Version:** 23  
**Document type:** changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- Work-offline mute (`open` without `live()`) is a hard threshold for
  automatic mail. `notifyResumed` still pokes a half-open live socket,
  but it does not run catch-up push/pull until `live()` has started.
  macOS window focus fires `AppLifecycleState.resumed`; that must not
  leak muted edits. Explicit `syncOnce` remains mute-exit.

### Changed

- After hello (or pull / live `cursor` with `server_now_ms`), outgoing
  `last_edited_at_ms` is store time plus the engine’s device offset, so a
  skewed device no longer wins last-write-wins against a later real edit
  once both have sampled store time. Completeness stays `server_seq`.
  The first sample rewrites dirty rows of this installation’s
  `source_id` only; incoming ranks are stored as they arrived.
  Intentional clock tampering after a sample is still not promised
  (proposal §12.1). The application does not call NTP and does not pass
  `nowMs` in production.
- With `live()` running, `write` / `writeAll` / `markChanged` schedule
  engine catch-up themselves. The edit future completes after persist: it
  does not wait for HTTP and does not throw `UlsyncNetworkException`.
  Push and pull no longer hold the serial lock, so a second `write` is
  not blocked on `kPushPullTimeout`. Dirty after `200` clears only when
  the stored `(id, part, revision)` still matches the posted snapshot —
  an edit of the same cell during that POST is not dropped. Two offline
  edits of one cell still last-write-wins, as in the product. `syncOnce`
  remains for first sign-in, mute-exit, and tests; it is not the outage
  retry the application must remember while the feed is live.
- **Breaking.** [EntityAdapter.apply] and [applyPart] receive
  [IncomingEnvelopeMeta] with wire `created_at_ms` and `last_edited_at_ms`
  so applications can sort and display consistently after sync.
- The engine reopens live on drop, retries `syncOnce` after
  `SyncConnectionRestored` until the server answers, and exposes
  `UlsyncClient.notifyResumed` for isolate wake (Flutter lifecycle
  cannot be observed from `lib/`). `SyncTransport.pokeLive` drops a
  half-open socket immediately.
- Record kits (`full` plus every named part of one id) are **indivisible**
  and must be **complete**. Ingest skips only a strictly older version of
  the **same** `(id, part)`. A three-rank tie still applies. Push, pull,
  and diff never split a kit at the SPEC ceiling of 500: a POST may be
  shorter than 500, a full pull page holds the trailing id, and diff
  probes of one id stay in one request. [syncOnce] replays the feed when
  library metadata remembers any cell that [EntityAdapter.load] no longer
  returns.
- **Breaking.** The only public way to construct a client is
  `UlsyncClient.open(name: …)`. `name` is an installation-local label,
  not a filesystem path. The generative constructor and the metadata
  store field are private. `SembastMetadataStore` and `EntityState` are
  no longer exported from `package:ulsync/ulsync.dart`. Callers that
  imported those types or passed `store:` will not compile.
- **Breaking.** `EntityAdapter.listIds` is required. Local
  reconciliation cannot be switched off by omitting the callback. An
  empty list is legal. `SelfCheckReport.localAvailable` is `false` only
  when the client has no adapters.
- The library resolves the metadata location itself: IndexedDB
  `ulsync_<name>` on the web (no `path_provider`), Application Support
  `{support}/ulsync/<name>.db` on IO. `path_provider` `^2.1.6` is a
  package dependency (lock `2.1.6`); applications do not call it. Engine
  tests pass
  `inMemory: true` so VM `flutter test` never hits
  `MissingPluginException`.
- iOS still backs up Application Support unless the app sets
  `NSURLIsExcludedFromBackupKey`. This release does not set that flag.
- The round-1 constructor compatibility test is removed. There is no
  published-package duty to keep the unpublished constructor compiling.
- The dirty queue posts complete record kits in one `POST /v1/sync/push`
  (`kPushBatchLimit` is the SPEC maximum of 500). A kit is never split
  to fill that ceiling. Marks clear only after
  that response, including `applied: false`. A thrown transport error
  leaves posted marks set. HTTP 413 is not retried as single-envelope
  POSTs.
- Self-check of unknown local ids uses time `1` (not `0`): older than any
  real edit, and the server accepts it. Time `0` was rejected on push, so
  G4 never healed.
- Live reconnect waits a fixed few seconds like EventSource; the wait does
  not grow. Live headers time out after 5 seconds when the server is down.
  `live()` no longer pulls before opening the feed.

### Added

- `WriteOp` and `UlsyncClient.writeAll`: one related edit under the same
  serial lock as `write`, so the live feed cannot POST the first rows
  while the rest are still being persisted. Empty list is a no-op. There
  is no transaction across the application store and the metadata file.
- Named envelope parts besides `full`. `UlsyncClient.write` and
  `markChanged` take an optional `part` (default `full`). Optional
  `EntityAdapter.encodePart` / `applyPart` send and apply those slices
  as independent cells. `apply` of a full snapshot must not write slice
  fields. There is no tombstone type; hide is an application part, not a
  `flags` bit.
- Required `UlsyncClient.origin` (SPEC section 1.5). Empty or illegal
  strings throw `ArgumentError` at construction; the library never mints
  the value. `GET /v1/sync/hello` runs before `selfCheck` and before
  `live` opens. `409` is `OriginMismatchException` (foreign store). An
  old server without the hello endpoint (`404` / `405`) keeps working as
  in round 1a. `HttpSyncTransport` sends `Ulsync-Origin` on hello, push,
  pull, diff, and live.
- `UlsyncClient.selfCheck`: three-phase anti-entropy (installation identity,
  application ids vs metadata, metadata vs `POST /v1/sync/diff`). Runs once
  per client on the first `syncOnce`. Marking an already-known row does not
  change its conflict clock. `listIds` on the adapter is required.
- `UlsyncClient.write`: marks a record dirty before the application persist
  callback runs, under the same serial lock, so a local edit cannot miss the
  send queue. `markChanged` stays as the low-level primitive.
- Engine **auto-heal** when local metadata cursor is ahead of the server feed
  head (for example after a server-side store reset): compare `L` to `H` via
  `pull(since: 0)`, reset local cursor when `L > H`, replay from `since=0`
  without mutating the server.
- Example application: two-window self-hosted to-do with done, trash,
  restore, session strip (host, not token), Immich-style pairing, and
  **Move done to trash** via `writeAll`. Tap journal removed.

## [0.1.0] - 2026-09-04

### Added

- Sync engine (`UlsyncClient`, `EntityAdapter`, `SyncReport`, `SyncEvent`):
  dirty queue, last-write-wins apply, live feed, internal lock.
- Example application (`example/`): one memo, `Save and sync`, live events.
- HTTP transport (`HttpSyncTransport`, `SyncTransport`): push, pull, and a
  live Server-Sent Events feed.
- Live connection lost/restored via `onConnectionState` on `live` (not a
  fourth `LiveMessage`).
- Typed transport failures split by whether the caller should retry
  (`UlsyncNetworkException`, `UlsyncServerException`, `UlsyncUnauthorized`,
  `UlsyncRequestRejected`).
- Live feed reconnects with a silence watchdog and a fixed pause between
  tries; the outward stream does not complete on a dropped socket.
- Live feed reopens 60 seconds before JWT `exp` (the claim is read; the
  signature is not verified). Unreadable `exp` falls back to 30 minutes.
- Per-user metadata store on sembast (`SembastMetadataStore`, `EntityState`):
  cursor, dirty queue with conditional clear, atomic `applyIncoming`.
- Replaced `sqflite` with `sembast` and `sembast_web` so the store runs on every
  Flutter platform, including the browser.
- CI runs `flutter test --platform chrome test/store/` on every push to prove the
  browser store path, not only document it. CI also analyzes `example/`.
- Package skeleton: strict analyzer, single public library file, protocol git
  submodule, CI workflow, and a test that forbids Flutter imports in the
  protocol core.
- Hand-written envelope codec with `fromJson` / `toJson` against protocol
  fixtures.
- `UlsyncProtocolException` with the offending field name on format mismatch.
- Internal live-feed line parser (not exported).
- Tests against protocol fixtures including non-UTF-8 payload bytes.

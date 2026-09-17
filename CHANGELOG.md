# Changelog

**Created:** 2026-09-01 14:25:15 +0500  
**Updated:** 2026-09-17 15:30:57 +0300  
**Version:** 16  
**Document type:** changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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
  change its conflict clock. `listIds` on the adapter is optional.
- `UlsyncClient.write`: marks a record dirty before the application persist
  callback runs, under the same serial lock, so a local edit cannot miss the
  send queue. `markChanged` stays as the low-level primitive.
- Engine **auto-heal** when local metadata cursor is ahead of the server feed
  head (for example after a server-side store reset): compare `L` to `H` via
  `pull(since: 0)`, reset local cursor when `L > H`, replay from `since=0`
  without mutating the server.

### Changed

- Self-check of unknown local ids uses time `1` (not `0`): older than any
  real edit, and the server accepts it. Time `0` was rejected on push, so
  G4 never healed.
- Live reconnect waits a fixed few seconds like EventSource; the wait does
  not grow. Live headers time out after 5 seconds when the server is down.
  `live()` no longer pulls before opening the feed.
- Example application: tap counter with two macOS processes, per-device
  metadata file, and an Offline switch; memo text field removed.

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

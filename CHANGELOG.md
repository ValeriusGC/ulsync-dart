# Changelog

**Created:** 2026-09-01 14:25:15 +0500  
**Updated:** 2026-09-08 09:55:00 +0300  
**Version:** 9  
**Document type:** changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Engine auto-heal when local metadata cursor is ahead of the server feed
  head (for example after a server-side store reset): replay from `since=0`
  without mutating the server.

### Changed

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
- Live feed reconnects with a silence watchdog and jittered backoff; the
  outward stream does not complete on a dropped socket.
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

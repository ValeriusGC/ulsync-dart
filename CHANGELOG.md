# Changelog

**Created:** 2026-09-01 14:25:15 +0500  
**Updated:** 2026-09-03 18:07:56 +0500  
**Version:** 3  
**Document type:** changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Per-user metadata store on sembast (`SembastMetadataStore`, `EntityState`):
  cursor, dirty queue with conditional clear, atomic `applyIncoming`.
- Replaced `sqflite` with `sembast` and `sembast_web` so the store runs on every
  Flutter platform, including the browser.

### Added (earlier)

- Package skeleton: strict analyzer, single public library file, protocol git
  submodule, CI workflow, and a test that forbids Flutter imports in the
  protocol core.
- Hand-written envelope codec with `fromJson` / `toJson` against protocol
  fixtures.
- `UlsyncProtocolException` with the offending field name on format mismatch.
- Internal live-feed line parser (not exported).
- Tests against protocol fixtures including non-UTF-8 payload bytes.

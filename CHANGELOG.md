# Changelog

**Created:** 2026-09-01 14:25:15 +0500  
**Updated:** 2026-09-02 21:31:28 +0500  
**Version:** 2  
**Document type:** changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Package skeleton: strict analyzer, single public library file, protocol git
  submodule, CI workflow, and a test that forbids Flutter imports in the
  protocol core.
- Hand-written envelope codec with `fromJson` / `toJson` against protocol
  fixtures.
- `UlsyncProtocolException` with the offending field name on format mismatch.
- Internal live-feed line parser (not exported).
- Tests against protocol fixtures including non-UTF-8 payload bytes.

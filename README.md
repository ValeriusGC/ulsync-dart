# ulsync

**Created:** 2026-09-01 14:25:15 +0500  
**Updated:** 2026-09-03 18:07:56 +0500  
**Version:** 3  
**Document type:** readme

## What this is

Entity-level last-write-wins synchronization client for Flutter applications.
The wire format lives in the `protocol/` git submodule pointing at
[ulsync-protocol](https://github.com/ValeriusGC/ulsync-protocol).
This repository is named `ulsync-dart` so other language SDKs can sit beside it
without sharing a package name.

## What this is not

- Not an identity provider — the application supplies the bearer token.
- Not a replacement for the application's local database — the library keeps
  its own metadata database, separate from the application's own storage.
- Does not invent a custom merge for the application — round 1 is mechanical
  last-write-wins on the envelope.

## Status

Working name only: `publish_to: none` in `pubspec.yaml`. Not published on
pub.dev.

## Installation

Path dependency (used by the reference application in step 15):

```yaml
dependencies:
  ulsync:
    path: ../ulsync-dart
```

Do not run `flutter pub add ulsync` — the package is not on pub.dev.

## Minimal setup

The snippet below is the **goal of step 14**; it **does not compile** in this
revision.

```dart
// On the web there is no documents directory: the path is just a store name.
final databasePath = kIsWeb
    ? 'ulsync.db'
    : '${(await getApplicationDocumentsDirectory()).path}/ulsync.db';

final client = UlsyncClient(
  baseUrl: Uri.parse('http://10.0.2.2:8080'),
  userScope: userId,
  sourceId: deviceId,
  tokenProvider: () async => supabase.auth.currentSession?.accessToken,
  store: await SembastMetadataStore.open(databasePath: databasePath),
  adapters: [
    EntityAdapter<CounterOperation>(
      entityType: 'counter_operation',
      schemaVersion: 1,
      encode: (op) => utf8.encode(jsonEncode(op.toJson())),
      decode: (bytes, schemaVersion) => CounterOperation.fromJson(...),
      load: (String id) async => localOpLog.byId(id),
      apply: (op) async => localOpLog.upsert(op),
    ),
  ],
);

await client.markChanged(entityType: 'counter_operation', id: opId);
final result = await client.syncOnce();
final subscription = client.live().listen(/* ... */);
```

## Local metadata

The library keeps a **separate** sembast database file for sync metadata only.
Application tables and migrations are never touched.

**What is stored:** creation and edit timestamps, revision number, originating
`source_id`, schema version, a pending-push (`dirty`) flag, and the server feed
cursor per `userScope`.

**What is not stored:** entity payloads (the application adapter supplies
content at push time), bearer tokens, or any user identifier beyond the
`userScope` string the application passes in.

**Path vs implementation.** The application supplies `databasePath` — a file
path on mobile and desktop, a store name in the browser. The library picks the
platform `DatabaseFactory` internally via a conditional export, so the
application writes no conditional import for storage.

**Optional `factory`.** `SembastMetadataStore.open` accepts an optional
`factory` for **application tests only** (for example
`databaseFactoryMemory`). It is not how production code selects a platform.

**`userScope` is mandatory.** Cursor and entity keys include `userScope`. If
the application forgets to scope by signed-in user, the next account on the
same device inherits the previous user's cursor and silently misses part of its
own feed.

## Protocol

Contract repository: https://github.com/ValeriusGC/ulsync-protocol

After cloning, initialize the submodule:

```bash
git clone --recurse-submodules git@github.com:ValeriusGC/ulsync-dart.git
# or, in an existing checkout:
git submodule update --init
```

Fixtures under `protocol/` are part of the contract — do not copy them into
`test/`.

## Wire format

The envelope shape is defined in [`protocol/SPEC.md`](protocol/SPEC.md) and
the upstream repository
[ulsync-protocol](https://github.com/ValeriusGC/ulsync-protocol). This
package serializes envelopes by hand — no code generation.

**Base64 alphabet.** The `payload` field on the wire is a string encoded with
RFC 4648 section 4 (standard alphabet with `+`, `/`, and `=` padding). Use
`base64Encode` and `base64Decode` from `dart:convert`. Do **not** use the URL
alphabet (`base64UrlEncode` / `base64UrlDecode`): Go's server uses
`StdEncoding`, and the mismatch only shows up on bytes that contain `+` or
`/`. See `protocol/fixtures/envelope/non_utf8_payload.json` for a fixture that
fails if the wrong alphabet is chosen.

**Fields absent from the wire JSON.** `user_id` never appears in an envelope;
the owner comes from the bearer token. `server_seq` is present on pull and live
responses but omitted when pushing (`null` means the key is absent in
`toJson`, not `"server_seq": null`).

**Forward compatibility.** Unknown JSON keys are ignored (SPEC section 6) so the
server can add fields without breaking existing clients.

## Development

```bash
cd /Users/vvk/AndroidStudioProjects/r/ulsync-dart
flutter pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
flutter test
```

## License

Apache License 2.0 — see `LICENSE` and `NOTICE`. A client library that needs
a legal review before import will not be imported.

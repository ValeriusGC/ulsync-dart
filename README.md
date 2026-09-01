# ulsync

**Created:** 2026-09-01 14:25:15 +0500  
**Updated:** 2026-09-01 14:25:15 +0500  
**Version:** 1  
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
  its own metadata SQLite; application tables stay in the application.
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
final client = UlsyncClient(
  baseUrl: Uri.parse('http://10.0.2.2:8080'),
  userScope: userId,
  sourceId: deviceId,
  tokenProvider: () async => supabase.auth.currentSession?.accessToken,
  store: await SqfliteMetadataStore.open(),
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

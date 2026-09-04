# ulsync

**Created:** 2026-09-01 14:25:15 +0500  
**Updated:** 2026-09-04 10:04:59 +0500  
**Version:** 6  
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

**Sizing.** On a developer machine, 10 000 entities occupy about 2.4 MB on disk
and reopen in about 69 ms (`flutter test --dart-define=ULSYNC_MEASURE=true
test/store/metadata_store_measure_test.dart`). The whole database is held in
memory while open, so treat hundreds of thousands of entities per user as out
of scope for this release.

**Mobile and desktop.** Pass a file path under the application documents
directory (for example via `path_provider`):

```dart
final databasePath =
    '${(await getApplicationDocumentsDirectory()).path}/ulsync.db';
final store = await SembastMetadataStore.open(databasePath: databasePath);
```

**Browser.** There is no file system path — pass a store name:

```dart
const databasePath = 'ulsync.db';
final store = await SembastMetadataStore.open(databasePath: databasePath);
```

The library picks `databaseFactoryIo` or `databaseFactoryWeb` internally; the
application writes no conditional import for storage.

**Application tests.** Pass an in-memory factory explicitly:

```dart
import 'package:sembast/sembast_memory.dart';

final store = await SembastMetadataStore.open(
  databasePath: 'test.db',
  factory: databaseFactoryMemory,
);
```

**Browser guarantee.** The store is exercised in Chrome on every CI run
(`flutter test --platform chrome test/store/`), not merely claimed in this
README.

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

## Transport

The library talks to the server through one `http.Client` for the lifetime of
the transport object. Reusing the client keeps TCP and TLS connections alive
(HTTP keep-alive). Creating a new client per request would handshake again
every few minutes, which on a phone is both slow and expensive.

`push` and `pull` wait at most 30 seconds for a complete response. The live
feed (`GET /v1/sync/pull?live=sse`) has no overall deadline — it is meant to
stay open. Waiting for **headers** of that request still uses the 30-second
budget; after the stream is open, a **silence watchdog** of 45 seconds takes
over. 45 seconds is three times the server's `live_heartbeat` (15 seconds in
the server's `config.example.yaml`).

The client must know that heartbeat period even though the server already
writes `: ping`. A mobile carrier NAT (network address translation) closes
idle TCP sockets without sending RST. The client's TCP stack then sits on a
half-open connection for minutes or forever, and the application shows stale
data. A server heartbeat that nobody watches is traffic without a diagnosis.
The watchdog is reset on every byte of the response body, including a partial
UTF-8 chunk, not only on a parsed event.

Failures are typed so the engine (step 14) can decide retry versus stop:

- `UlsyncNetworkException` and `UlsyncServerException` (HTTP 5xx) are
  retryable. `push` and `pull` do **not** retry them; they throw and leave
  the loop to the engine. The live feed reconnects on its own because the
  outward stream must not complete on a dropped socket.
- `UlsyncRequestRejected` (HTTP 4xx other than a single 401 retry) is not
  retried: the server will give the same answer. Looping on 413 drains the
  battery and the traffic budget.
- `UlsyncUnauthorized` is a missing or empty token, or HTTP 401 after one
  retry with a fresh token from `tokenProvider`.
- `UlsyncProtocolException` means the bytes did not match the contract; it is
  not retried.

After a live disconnect, the transport waits 1 second, then 2, 4, and so on,
up to a **base** of 30 seconds, and then adds a random delay of up to that
same base (full jitter). Capping the *total* at 30 seconds would squeeze
jitter to zero at the ceiling and recreate the reconnect storm that jitter
exists to prevent. The backoff counter resets only after a connection has
stayed up for at least one minute; a connect-and-drop loop is not treated as
success. Round 1 does not open `live=poll`.

The transport does not store a cursor. Each (re)open of the live feed calls
`appliedSince` and sends that integer as `since`. That callback must return
the cursor the engine has **applied**, not the last `cursor` event observed:
reopening from a cursor that was only seen would skip the rest of a batch
that was cut in half by a disconnect.

`tokenProvider` is called before every HTTP request, including the one-time
retry after 401, because the application may have rotated the session. An
empty or `null` token becomes `UlsyncUnauthorized` without touching the
network. The live feed is reopened 60 seconds before the JWT `exp` claim, so
the new handshake still has a valid token. The client reads `exp` as an open
JSON field; it does **not** verify the signature — the server does that when
the stream opens. If `exp` cannot be read, the feed is reopened every 30
minutes rather than immediately or never.

Cleartext HTTP (`http://`) on Android is blocked by default. Enabling it
(`android:usesCleartextTraffic` or a network-security config) is an
**application** setting (step 15), not something this library turns on. The
package does not ship an Android manifest and will not add one.

## Development

```bash
cd /Users/vvk/AndroidStudioProjects/r/ulsync-dart
flutter pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
flutter test
flutter test --platform chrome test/store/
```

The Chrome run exercises the metadata store through the default platform
factory; CI runs the same command on every push.

## License

Apache License 2.0 — see `LICENSE` and `NOTICE`. A client library that needs
a legal review before import will not be imported.

# ulsync

**Created:** 2026-09-01 14:25:15 +0500  
**Updated:** 2026-09-08 09:55:00 +0300  
**Version:** 9  
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

## Getting started

The application talks to four types: `UlsyncClient`, `EntityAdapter`,
`SyncReport`, and `SyncEvent`. Cursor, send queue, last-write-wins, retries
of a dropped live socket, and the wire format stay inside the library.

```dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ulsync/ulsync.dart';

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
final subscription = client.live().listen((event) {
  // Update the screen from SyncEvent. Do not parse envelopes.
});
```

`10.0.2.2` is the host loopback as seen from an Android emulator. On a
macOS or iOS simulator use `http://127.0.0.1:8080`. The `example/` app
reads the same values from `--dart-define` so it is not an identity
provider.

To see a click move between two windows, run the `example/` app twice on
macOS as described in [`example/README.md`](example/README.md): one build,
two `open -n` launches, different Device ID values, one local server. The
example uses a tap journal (`counter_operation`) instead of a single integer
so concurrent pluses both arrive. An **Offline** switch per window queues
local edits without closing the client.

**`baseUrl`.** Origin of the ulsync server (`http://host:port`). Path
prefixes such as `/api` are not supported; requests always go to
`/v1/sync/push` and `/v1/sync/pull`. Ignored when a test supplies
`transport`, but still required so production and tests share one
constructor.

**`userScope`.** The signed-in user. It is part of every metadata key. A
different account on the same device must not inherit the previous
cursor — that would silently skip part of the new user's feed. Pass a
new `UlsyncClient` (or a new `userScope` on a fresh client) after
sign-in; do not "reset on sign-out" as a best-effort extra call.

**`sourceId`.** Stable installation id, written to envelope `source_id`.
It is the third last-write-wins rank when edit time and revision tie.
The library never invents it: only the application knows what counts as
a device and only the application can persist it across launches.

**`tokenProvider`.** Called before every HTTP request, including the
one-time 401 retry. Return the current access token, or `null` / blank
to fail fast with `UlsyncUnauthorized` and no network call. The library
does not refresh sessions; it re-reads whatever the application now
holds.

**`store`.** The library's metadata database (cursor, dirty queue,
revision). The application chooses the path; the library chooses the
sembast factory for the platform. See **Local metadata** below. Entity
payloads are **not** copied here — `load` reads them from the
application store at push time.

**`adapters`.** One `EntityAdapter<T>` per `entity_type` the application
understands. Duplicate types throw at construction. A type that arrives
from the server with no adapter is skipped, the cursor still advances,
and `SyncUnknownType` is emitted — a foreign type must not stop sync of
the types you do own.

**`apply` must be idempotent.** The application store and the metadata
database are different databases. There is no transaction that covers
both. The engine therefore writes the application store first
(`decode` + `apply`) and only then persists metadata and the cursor. If
the process dies between those two writes, the next pull or live event
delivers the same envelope again and `apply` runs a second time. An
upsert by `id` is safe; an append without dedup duplicates the record.
The opposite order (cursor first) would skip the record forever after
the same crash, so the engine does not use it.

Call `markChanged` after every local edit. The engine, not the
application, increments `revision`. Then call `syncOnce` when the
application decides it is a good time (foreground, not low battery).
The library does **not** start a timer.

Listen to `live()` for `SyncEvent` values:

- `SyncApplied` / `SyncCursorAdvanced` — refresh the screen from the
  application store; the payload is already in `apply`.
- `SyncConnectionLost` — show a disconnected state. Do not parse the
  protocol. The library reopens the feed on its own.
- `SyncConnectionRestored` — clear that state. After returning from
  background, still call `syncOnce`: the OS may have killed the socket
  in a way that looks like a clean close (see Limitations).
- `SyncUnknownType` — log it; sync of known types continues.

The application does not store the cursor or the send queue. Those live
in `SembastMetadataStore`.

## Limitations of round 1

- One envelope per `POST /v1/sync/push`. The dirty queue is already a
  list; round 2 changes the **body** of the push loop, not the queue.
- No deletion, no tombstones, no `part` other than `full`.
- No payload compression, no clock-skew correction, no content schema
  migrations inside the library.
- The library does not call `syncOnce` on a timer. The application knows
  foreground, battery, and connectivity.
- `syncOnce` does not retry HTTP `5xx` or network errors. It throws and
  leaves `dirty` set so the application can call `syncOnce` again.
- `applied: false` is success: the server already holds a row that is
  not inferior. The engine clears `dirty` on both `true` and `false`.
  Retrying a rejected envelope loops forever because the upsert requires
  a strictly superior tuple.
- A live socket closed by the OS in the background is caught up by an
  ordinary `syncOnce` when the application returns to the foreground.
  That is the same limit PowerSync and PocketBase document.
- The `example/` app is not promised against a local server from Chrome:
  `ulsync-server` does not send CORS headers. Use macOS or an Android
  emulator.

## Local metadata

The library keeps a **separate** sembast database file for sync metadata only.
Application tables and migrations are never touched.

**What is stored:** creation and edit timestamps, revision number, originating
`source_id`, schema version, a pending-push (`dirty`) flag, and the server feed
cursor per `userScope`.

**Cursor ahead of the server.** If the server store was reset or replaced while
this metadata file survived, the local cursor can be higher than the server's
feed head. Pull and live would then skip new rows with no error. Before each
[`syncOnce`](lib/src/engine/sync_engine.dart) and when opening the live feed,
the engine compares the stored cursor to the server head (via `pull(since: 0)`)
and, when local is ahead, resets the cursor and replays from the beginning.
The server is not modified; [`EntityAdapter.apply`](lib/src/engine/entity_adapter.dart)
must be idempotent. Sign out and a fresh metadata file are still required when
changing accounts (`userScope`).

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

Failures are typed so `UlsyncClient.syncOnce` can decide retry versus stop:

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

Cleartext HTTP (`http://`) on Android is blocked by default. The example
enables it only in the **debug** manifest
(`android:usesCleartextTraffic="true"`). Production apps that talk HTTP
must set this themselves; the library does not ship an Android manifest.

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

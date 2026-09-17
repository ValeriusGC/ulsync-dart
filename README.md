# ulsync

**Created:** 2026-09-01 14:25:15 +0500  
**Updated:** 2026-09-17 15:30:57 +0300  
**Version:** 14  
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

The application talks to five types: `UlsyncClient`, `EntityAdapter`,
`SyncReport`, `SyncEvent`, and `SelfCheckReport`. Cursor, send queue,
last-write-wins, retries of a dropped live socket, the self-check, and the
wire format stay inside the library. Local edits go through
`UlsyncClient.write` so a dirty mark cannot be forgotten; `markChanged`
remains as a low-level primitive (see **Recording a local edit** below).
The first network call of each client is an origin handshake
(see **Origin**); the library then runs a self-check once on the first
`syncOnce` (see **Self-check**).

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
  origin: 'com.example.app/7c3e9a12-4b56-4d8e-9f01-2a3b4c5d6e7f',
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

await client.write(
  entityType: 'counter_operation',
  id: opId,
  persist: () => localOpLog.append(op),
);
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
`/v1/sync/hello`, `/v1/sync/push`, `/v1/sync/pull`, and `/v1/sync/diff`.
Ignored when a test supplies `transport`, but still required so production
and tests share one constructor.

**`origin`.** Application-contour name sent as `Ulsync-Origin` (SPEC
section 1.5). Required. Empty, blank, longer than 256 characters, or
outside the SPEC character class is `ArgumentError` at construction —
the network is not touched. Not a URL and not `userScope`. See **Origin**.

**`userScope`.** The signed-in user. It is part of every metadata key. A
different account on the same device must not inherit the previous
cursor — that would silently skip part of the new user's feed. Pass a
new `UlsyncClient` (or a new `userScope` on a fresh client) after
sign-in; do not "reset on sign-out" as a best-effort extra call.

**`sourceId`.** Stable installation id, written to envelope `source_id`.
It is the third last-write-wins rank when edit time and revision tie
(SPEC section 2). The library never invents it: only the application
knows what counts as a device and only the application can persist it
across launches. SPEC section 1.4 requires it to be unique per
installation — mint it once, keep it out of platform backups, and do
not let it change between launches. The library remembers the value on
first open and throws `StateError` if a later client opens the same
metadata file with a different id (see **Self-check**).

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
the types you do own. Optional `listIds` lets the self-check compare
application data with library metadata; without it that phase reports
unavailable and everything else still works. Optional `encodePart` /
`applyPart` send and apply named envelope parts other than `full`
(see **Named parts**). Existing adapters without those fields keep
compiling.

**`apply` must be idempotent.** The application store and the metadata
database are different databases. There is no transaction that covers
both. The engine therefore writes the application store first
(`decode` + `apply`) and only then persists metadata and the cursor. If
the process dies between those two writes, the next pull or live event
delivers the same envelope again and `apply` runs a second time. An
upsert by `id` is safe; an append without dedup duplicates the record.
The opposite order (cursor first) would skip the record forever after
the same crash, so the engine does not use it.

## Origin

`origin` names the **application contour** this client belongs to: one
deployment of one application (production, staging, or a private
server). It is not the server URL, not `userScope`, and not `sourceId`.
The analog is SQLite `PRAGMA application_id` or an Android
`applicationId`: the store is marked “this application”, not “this
phone”.

Recommended form: reverse-DNS of the application plus a **project**
UUID (Universally Unique Identifier), kept in source control next to
the server URL:

```
com.company.app/7c3e9a12-4b56-4d8e-9f01-2a3b4c5d6e7f
```

Mint that UUID once when the project is created. Every installation of
this contour sends the same string. A UUID minted on the device at
first launch would make the second phone a foreign client forever —
that is a protocol violation, and this library will not invent
`origin` for you.

SPEC section 1.5 character class: `A–Z`, `a–z`, `0–9`, `.`, `_`, `/`,
`-`. Length 1–256 after trim. Anything else is `ArgumentError` at
construction.

Two modes live on the server (see the
[ulsync-server README](https://github.com/ValeriusGC/ulsync-server)):

- **Open store** — no `origin` in server config. The first well-formed
  `GET /v1/sync/hello` imprints the store. Later clients with a
  different string are refused.
- **Authored store** — the operator set `origin` in `config.yaml`
  before any client. A different string (or a missing header on that
  server) is refused even while the envelope table is empty.

HTTP transport sends `Ulsync-Origin` on hello, push, pull, diff, and
live. A test double without HTTP does not send a header; that is
expected.

The first network action of a `UlsyncClient` instance is
`GET /v1/sync/hello`, **before** `selfCheck` and **before** the live
feed opens. `write` does not call hello: local data stays on the
device until the next exchange. Hello runs outside the engine serial
lock, the same rule as `selfCheck`.

| Server response | Client |
|---|---|
| `200` | Handshake done for this instance; `syncOnce` / `live` continue |
| `404` or `405` | Endpoint absent (old server). Handshake marked unavailable; exchange continues as in round 1a. There is no foreign-store gate on that server |
| `409` | `OriginMismatchException` naming `storeOrigin` and `requestOrigin`. The done flag is **not** set: the next call repeats the refusal. Point this application at the store the constant was built for, or change the constant and the store configuration together. The library will not rewrite `origin` |
| Network error | Flag not set; the error is thrown; the next `syncOnce` retries hello |

A transport that does not implement `SyncHelloTransport` is treated as
hello-unavailable (test doubles and custom non-HTTP transports).

## Recording a local edit

The recommended path is `UlsyncClient.write`. The library marks the record
dirty **first**, then runs the application's persist callback, and it holds
the internal serial lock for the whole callback.

That order is not taste. The library metadata database and the
application's store cannot share a transaction, so a crash in the middle
must pick a side:

- Mark without data is safe. The next `syncOnce` calls `load`, gets
  `null`, and already clears the dirty flag without POSTing.
- Data without a mark is a silent permanent loss. Nothing will ever
  send the row. Nobody notices.

Holding the lock during `persist` is the other half of the same
invariant. If the lock were released between the mark and the
application write, a concurrent `syncOnce` could see dirty, load
`null` (the row is not there yet), and clear the mark — the same
loss. Do **not** call `UlsyncClient` methods from inside `persist`.
That would wait on the lock forever; the library throws `StateError`
instead of hanging. Write only application data there.

```dart
await client.write(
  entityType: 'counter_operation',
  id: op.id,
  persist: () => localOpLog.append(op),
);
```

`markChanged` stays in the public API. It is a **low-level primitive**
for applications that cannot persist through the library. Calling it
*after* a local write can lose the record forever if the process dies,
the future is left unawaited, or the call is skipped. Prefer `write`.
The engine, not the application, increments `revision`.

Then call `syncOnce` when the application decides it is a good time
(foreground, not low battery). The library does **not** start a timer.
The first `syncOnce` of each client names `origin` to the server, then
runs the self-check.

## Named parts

An envelope is one cell: identity on the wire is `(id, part)`, not
`id` alone. `full` is the complete snapshot of the record. Any other
non-empty string is a slice the **application** names. The library
does not keep a registry of those names, does not know “trash”, and
does not treat `done` or `deleted` as reserved protocol values — those
two strings are examples an app may choose, nothing more.

Last-write-wins already compares inside one `(id, part)` pair and
does not jump to a neighbour. That is not enough in the domain. The
library does not store part bodies to replay “snapshot, then newer
slices”. Each winning envelope is applied to **its own columns** on
arrival. `EntityAdapter.apply` runs only for `full` and must write
only snapshot fields (the title, the body). `applyPart` runs for every
other name and must write only that slice (the checkbox, the hide
flag). If `apply` of `full` also writes those flags, a newer snapshot
clears them and the independence the wire already kept is lost in the
application store. The library cannot see that bug; the adapter is
the contract.

`UlsyncClient.write` takes an optional named `part` (default `full`).
The dirty mark is keyed the same way metadata already is: `(id, part)`.
A blank `part` after trim is `ArgumentError`. `markChanged` takes the
same optional argument so the primitive cannot mark `full` while the
application thinks it edited another slice.

Push: `part == full` still uses `load` then `encode`. Any other part
calls `encodePart`. `encodePart` returning `null` is the same contract
as `load` returning `null`: the dirty flag is cleared and there is no
POST. Calling `write(part: x)` with `x != full` when `encodePart` is
omitted throws `StateError` **before** the dirty mark, and `persist`
does not run — a missing encoder must not leave a row that cannot be
sent.

Pull and live: `part == full` still uses `decode` then `apply`. Any
other part calls `applyPart`. If `applyPart` is omitted, the envelope
does **not** fail the exchange: the cursor still advances, the part’s
metadata is stored so the same bytes are not replayed forever, and
the application store is left untouched. That is how an older build
ignores a slice it does not yet understand.

This step still sends **one envelope per POST**. Batching the dirty
queue is a later change. There is no tombstone type and no hide bit
in `flags` (`flags` stay `0`).

```dart
await client.write(
  entityType: 'task',
  id: task.id,
  persist: () => db.upsertTitle(task),
);

await client.write(
  entityType: 'task',
  id: task.id,
  part: 'done',
  persist: () => db.writeDone(task.id, true),
);
```

## Self-check

The library can push what it marked and pull what appeared on the
server. It cannot, by itself, see records the application wrote before
ulsync was wired, a restored backup, or a row that vanished only on
the server. `selfCheck` finds that divergence and repairs it without
asking where it came from.

The application normally **never** calls `selfCheck`. The library runs
it once per client instance on the first `syncOnce`, **after** the origin
handshake succeeds or is unavailable — sign-in and account switch, which
is when it is needed. There is no timer and it is not invoked from `live`.

Three phases, in order:

1. **Installation identity.** On first open the library stores
   `source_id` in the metadata database. A later mismatch throws
   `StateError` naming both values. Quietly continuing would swap the
   third conflict rank and two devices could keep different payloads
   forever (SPEC section 1.4). Restore the previous id, or if the
   change is intentional, delete the metadata file.
2. **Application data vs library metadata.** Optional
   `EntityAdapter.listIds` returns every id of that type the
   application stores — ids only, never payloads. For each id with no
   metadata the library creates a row with `last_edited_at_ms = 1`,
   `revision = 1`, and `dirty = true`. Time `1` is older than any real
   edit and is legal on the wire (the server rejects `created_at_ms <= 0`).
   If no adapter provides `listIds`, this phase reports itself
   unavailable and the rest of sync still works. Existing adapters
   keep compiling; the field is optional on purpose.
3. **Library metadata vs the server.** `POST /v1/sync/diff` (SPEC
   section 3.4) sends `(id, part)` plus the **three** ranks of SPEC
   section 2, in batches of 500. The server answers `missing` (no row)
   and `stale` (its row loses). The client does not compare ranks; it
   marks the named keys **without changing** edit time, creation time,
   or revision, then pushes through the ordinary queue. A server that
   does not implement the route (`404` / `405`), or a transport that
   cannot run the check, turns this phase off. That is a supported
   configuration, not an error.

A naive mark that stamped “now” would let a stale local copy defeat a
newer copy from another device. Reconciliation therefore has its own
mark, and it does not touch the conflict clock.

What to call:

| Situation | Call |
|---|---|
| Name the application contour | `origin:` on `UlsyncClient` — always. There is no setter. |
| Handshake with the store | nothing — `GET /v1/sync/hello` runs before the first `syncOnce` exchange and before `live` opens |
| Persist a local edit | `write` (preferred) or `markChanged` |
| Exchange with the server | `syncOnce` |
| Find and repair divergence | nothing — `selfCheck` runs on the first `syncOnce`. Call it only for a manual diagnostic. |

There are no public `reconcile` or `verify` methods. One action, one
report (`SelfCheckReport`): whether each phase was available, how many
rows it marked, and how many dirty rows remain.

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
  list; a later change batches the **body** of the push loop, not the
  queue. Named parts in this version still travel one POST each.
- There is no tombstone type. Hiding a record is an application part
  the library does not interpret. `flags` stay `0`.
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

**Auto-heal (cursor ahead of the server).** If the server store was reset or
replaced while this metadata file survived, the local cursor can be higher than
the server's feed head. Pull and live would then skip new rows with no error.
The engine **auto-heals** on every [`syncOnce`](lib/src/engine/sync_engine.dart)
and when opening the live feed:

1. Read the stored cursor `L` from this metadata file.
2. Probe the server feed head `H` with paginated `pull(since: 0)` (read-only).
3. When `L > H`, reset the local cursor to `0` and replay the feed from the
   beginning; [`EntityAdapter.apply`](lib/src/engine/entity_adapter.dart) must
   be idempotent so already-known rows are harmless.

The server is never modified by this step. Sign out and a fresh metadata file
are still required when changing accounts (`userScope`).

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

`HttpSyncTransport` sends `Ulsync-Origin` on every `/v1/sync/*` request.
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

After a live disconnect, the client does what EventSource does in the
browser: wait about 3 seconds, then try again. The wait does **not** grow.
The first open is immediate. If headers never arrive, this try stops after
5 seconds and the 3-second pause starts. Push and pull still wait up to 30
seconds for a slow round trip.

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

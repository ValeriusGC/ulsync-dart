/// Sync engine: dirty queue, last-write-wins apply, live feed, one mutex.
///
/// HTTP push and pull do not hold the mutex: a local [UlsyncClient.write]
/// must not wait on the transport timeout. After a local edit, if
/// [UlsyncClient.live] has already been started, the engine drains dirty
/// itself. Work-offline mute is [UlsyncClient.live] never started: write
/// does not push.
///
/// A record kit (`full` plus every named part of one id) is **indivisible**
/// and must be **complete**. Push, pull, and diff never cut that set at
/// the SPEC ceiling of 500; ingest never drops a cell because another
/// cell of the same id already applied.
///
/// Applications import [UlsyncClient] from `package:ulsync/ulsync.dart`.
/// Envelopes never leave this library as [SyncEvent] payloads.
/// @docImport '../transport/exceptions.dart';
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:sembast/sembast_memory.dart';

import '../protocol/envelope.dart';
import '../protocol/errors.dart';
import '../protocol/origin.dart';
import '../store/entity_state.dart';
import '../store/instance_name.dart';
import '../store/platform/metadata_path.dart';
import '../store/sembast_metadata_store.dart';
import '../transport/exceptions.dart';
import '../transport/http_sync_transport.dart';
import '../transport/sync_transport.dart';
import 'entity_adapter.dart';
import 'incoming_envelope_meta.dart';
import 'lww.dart';
import 'record_kit.dart';
import 'self_check_report.dart';
import 'sync_event.dart';
import 'sync_report.dart';

/// Default wire `part` for snapshot columns of a record.
///
/// SPEC section 1.1: identity is `(id, part)`. `full`, `done`, `deleted`,
/// and every other name are **equal cells** of one **indivisible,
/// complete** kit. The application row is the union of every cell for
/// that id, applied independently in feed order. `full` is the default
/// for [UlsyncClient.write] and [UlsyncClient.markChanged], not a
/// privileged snapshot that finishes the record. Last-write-wins never
/// compares one part against another. A SPEC batch of 500 must not cut
/// this kit in half.
const String kEnvelopePart = 'full';

/// Wire `payload_encoding`. Always `json` in round 1, even when the bytes
/// are not UTF-8: the server copies the string and does not interpret it.
const String kPayloadEncoding = 'json';

/// Wire `flags`. This version always sends `0`.
///
/// Hiding a record is an application part, not a bit in this field.
/// There is no tombstone type.
const int kFlags = 0;

/// SPEC maximum envelopes in one push, pull page, or diff request.
///
/// This is a ceiling, not a quota to fill. A record kit is **indivisible**:
/// the engine sends fewer than 500 rather than split `full` / `done` /
/// `deleted` of one id across two requests.
const int kSpecBatchLimit = 500;

/// Maximum dirty rows posted in one [UlsyncClient.syncOnce] drain.
///
/// Matches [kSpecBatchLimit] so a hundred-row related edit leaves in one
/// POST. The engine never fills those 500 by cutting a record kit:
/// `full` and every named part of one id are an **indivisible, complete**
/// set and travel together, even when that leaves the POST shorter than
/// this ceiling. A lower drain would split a hundred-row
/// [UlsyncClient.writeAll] across two [UlsyncClient.syncOnce] passes.
const int kPushBatchLimit = kSpecBatchLimit;

/// Page size for [SyncTransport.pull]. A full page triggers another request.
///
/// Matches [kSpecBatchLimit]. A full page still holds the trailing
/// `(entityType, id)` so an **indivisible** kit that straddles the
/// ceiling is not ingested without its remaining cells. Completeness
/// forbids applying `full` and leaving `done` on the next page.
const int kPullPageLimit = kSpecBatchLimit;

/// Maximum keys in one `POST /v1/sync/diff` (SPEC section 3.4).
///
/// Matches [kSpecBatchLimit]. Probes for one `id` are an **indivisible**
/// kit: they are never split across two requests, even when that leaves
/// a request shorter than 500.
const int kDiffBatchLimit = kSpecBatchLimit;

/// Mutable counters for one [UlsyncClient.syncOnce] pass.
final class _SyncCounters {
  /// Envelopes actually POSTed.
  int pushed = 0;

  /// Push rows with `applied: true`.
  int accepted = 0;

  /// Pull envelopes seen this pass, including skips.
  int pulled = 0;

  /// [EntityAdapter.apply] / [EntityAdapter.applyPart] calls this pass
  /// (not live). An unknown part with no `applyPart` does not increment
  /// this: the domain was not written.
  int applied = 0;
}

/// Zone key set while a [UlsyncClient.write] or [UlsyncClient.writeAll]
/// persist callback runs.
///
/// Nested [UlsyncClient] calls would wait forever on the serial lock; the
/// lock helper throws [StateError] instead of hanging.
final Object _writeZoneKey = Object();

/// One persist step of a [UlsyncClient.writeAll] list.
///
/// A related edit ("move done to trash") is several persist callbacks
/// that must not be visible to live sync until every mark is written.
/// Each [part] is one cell of an **indivisible, complete** kit.
/// [UlsyncClient.writeAll] holds the same lock as a single
/// [UlsyncClient.write] for the whole list, so the feed cannot POST the
/// first five while item 100 is still being persisted. This type does
/// not open a database transaction: the application store and the
/// metadata file remain two files, so a throwing persist on item 5
/// leaves 1–5 marked and 6…N not started.
final class WriteOp {
  /// Creates one persist step of a related edit.
  const WriteOp({
    required this.entityType,
    required this.id,
    required this.persist,
    this.part = kEnvelopePart,
  });

  /// Adapter key.
  ///
  /// An unknown name throws [ArgumentError] before this item's mark and
  /// persist; earlier items in the same [UlsyncClient.writeAll] have
  /// already run.
  final String entityType;

  /// Wire `id` of the record.
  final String id;

  /// Envelope cell. Default [kEnvelopePart] (`full`).
  ///
  /// Identity is `(id, part)`. One cell of an **indivisible, complete**
  /// kit — `full` does not finish the record. A blank value after trim
  /// is [ArgumentError] at [UlsyncClient.writeAll], not at construction.
  final String part;

  /// Application write for this item.
  ///
  /// Runs after the dirty mark, under the serial lock. Must not call
  /// [UlsyncClient] methods.
  final Future<void> Function() persist;
}

/// End-to-end last-write-wins client: the engine drives the wire.
///
/// A record kit (`full` plus every named part of one id) is **indivisible**
/// and must be **complete**. Open with [UlsyncClient.open]. Record local
/// edits with [write] or [writeAll]. Call [live] once after sign-in — that
/// starts the worry loop. Call [notifyResumed] when the **process** wakes;
/// the engine cannot see Flutter lifecycle (`lib/` must not import
/// `package:flutter`).
///
/// **The engine does, without being kicked:**
///
/// - Reopen the live SSE feed on drop, timeout, 5xx, and TCP death
///   ([kReconnectInterval], silence watchdog).
/// - Run [syncOnce] after every [SyncConnectionRestored] until push/pull
///   succeed, so envelopes missed while the socket was down still land.
/// - After a local [write] / [writeAll] / [markChanged], if [live] has
///   already been started, schedule that same catch-up. The application
///   does not call [syncOnce] after each edit. If [live] has not been
///   started, push is not invoked (Work-offline mute).
/// - Restart [live] if the transport stream ends without [close].
/// - Replay from `since=0` when the local cursor is ahead of the server,
///   or when metadata still names any cell of a kit (`full` or a named
///   part) that [EntityAdapter.load] no longer returns (sign-in cleared
///   an in-memory journal). The whole kit is replayed; `full` alone is
///   not a complete row.
///
/// **The engine cannot see, so the application must tell it:**
///
/// - App switcher, lock screen, laptop sleep, isolate freeze: Dart timers
///   do not fire, a half-open TCP socket looks healthy, and the 45s
///   silence watchdog is asleep too. Call [notifyResumed] from
///   `WidgetsBindingObserver.didChangeAppLifecycleState` when the state
///   is `AppLifecycleState.resumed`. That API drops the stale socket
///   **now** and catch-up-retries [syncOnce]. Listen to
///   [SyncConnectionLost] / [SyncConnectionRestored] for the strip; do
///   not call [syncOnce] from those events — the engine already does.
///
/// After the first `server_now_ms` sample, outgoing `created_at_ms` /
/// `last_edited_at_ms` are `nowMs` plus a stored offset so last-write-wins
/// compares devices in store time. Completeness is still `server_seq`.
/// JWT expiry and the live silence watchdog stay on `DateTime.now()`:
/// those are transport lifetimes, not SPEC section 2 ranks. The
/// application does not pass `nowMs` in production and does not call NTP.
///
/// [markChanged] remains as a low-level primitive. The first network
/// action of each instance is SPEC section 3.5 hello, then the first
/// [syncOnce] runs [selfCheck]. Protocol, HTTP, cursor, the metadata
/// engine, and the send queue stay inside.
final class UlsyncClient {
  /// Opens a client bound to one metadata instance named [name].
  ///
  /// [name] is an installation-local label (`phone`, `tablet`), not a
  /// filesystem path and not [origin]. Two processes that share a name
  /// share a cursor and a stored `source_id`. The library picks IndexedDB
  /// on the web and an Application Support file on IO; the application
  /// does not import `path_provider` and does not write `kIsWeb`.
  ///
  /// Pass [inMemory] only in tests. A VM test that resolves a real support
  /// directory will throw `MissingPluginException` from `path_provider`.
  /// The in-memory factory type is not part of the public API: this flag
  /// is the test seam, not a `DatabaseFactory` argument.
  ///
  /// After [close], a later [open] with the same [name] reopens that same
  /// metadata instance. Work offline can mute the live feed and come back
  /// without caching a filesystem path on the widget.
  ///
  /// [origin] is minted once per application contour in the application
  /// project, never per device, and is sent as `Ulsync-Origin`. Empty or
  /// illegal strings throw [ArgumentError] here so a forgotten origin
  /// cannot reach the network. When [transport] is omitted, the library
  /// builds [HttpSyncTransport] with the same [origin]. A caller-supplied
  /// HTTP transport must be constructed with that same string; non-HTTP
  /// test doubles ignore the header.
  ///
  /// [baseUrl] and [tokenProvider] are ignored when [transport] is provided;
  /// they remain required so production and tests share one [open] shape.
  /// The client still closes [transport] in [close], including a
  /// caller-supplied instance — passing a transport passes close ownership.
  ///
  /// [beforePersistIncoming] is test-only. It runs after
  /// [EntityAdapter.apply] and before metadata persist, which is the crash
  /// window between the two databases. There is no store interface (triad
  /// plan §13.9); this hook is the seam instead of `@visibleForTesting`,
  /// which would import Flutter into `lib/` and fail the import guard.
  ///
  /// [catchUpRetryDelay] is the pause between [syncOnce] attempts after a
  /// network miss on live restore, a local edit while [live] is running,
  /// or [notifyResumed]. Production keeps the default. Tests pass
  /// [Duration.zero] so a scripted failure does not wait a second.
  ///
  /// [nowMs] is test-only, the same kind of hatch as [inMemory]. It
  /// returns Unix milliseconds used to stamp a local edit. Production
  /// omits it so the engine reads `DateTime.now().millisecondsSinceEpoch`.
  /// The application must not pass this in a shipping build and must not
  /// call NTP to invent a better clock: after hello the engine already
  /// adds the stored store-clock offset. Passing it in product would
  /// teach every app to design time, which this library exists to hide.
  ///
  /// [pushBatchLimit] and [pullPageLimit] default to [kSpecBatchLimit].
  /// Tests pass a smaller ceiling to prove a record kit is not split at
  /// the batch edge. Production keeps the default. Values outside
  /// `1…kSpecBatchLimit` throw [ArgumentError].
  ///
  /// Throws [ArgumentError] when [name] fails [requireInstanceName], when
  /// [origin], [userScope], or [sourceId] are empty or illegal, or when
  /// [adapters] contains a duplicate [EntityAdapter.entityType]. Those
  /// checks run before the database opens and before the network is touched.
  static Future<UlsyncClient> open({
    required String name,
    required Uri baseUrl,
    required String origin,
    required String userScope,
    required String sourceId,
    required Future<String?> Function() tokenProvider,
    required List<EntityAdapter<dynamic>> adapters,
    SyncTransport? transport,
    bool inMemory = false,
    Future<void> Function()? beforePersistIncoming,
    Duration catchUpRetryDelay = const Duration(seconds: 1),
    int Function()? nowMs,
    int pushBatchLimit = kPushBatchLimit,
    int pullPageLimit = kPullPageLimit,
  }) async {
    final safeName = requireInstanceName(name);
    requireUlsyncOrigin(origin);
    _requireNonEmpty(userScope, 'userScope');
    _requireNonEmpty(sourceId, 'sourceId');
    _indexAdapters(adapters);
    final SembastMetadataStore metadataStore;
    if (inMemory) {
      metadataStore = await SembastMetadataStore.open(
        databasePath: safeName,
        factory: databaseFactoryMemory,
      );
    } else {
      metadataStore = await SembastMetadataStore.open(
        databasePath: await resolveMetadataDatabasePath(safeName),
      );
    }
    final storedClock = await metadataStore.readClockOffset(userScope);
    return UlsyncClient._(
      baseUrl: baseUrl,
      origin: origin,
      userScope: userScope,
      sourceId: sourceId,
      tokenProvider: tokenProvider,
      store: metadataStore,
      adapters: adapters,
      transport: transport,
      beforePersistIncoming: beforePersistIncoming,
      catchUpRetryDelay: catchUpRetryDelay,
      nowMs: nowMs ?? _systemNowMs,
      clockOffsetMs: storedClock?.offsetMs ?? 0,
      clockSampled: storedClock?.sampled ?? false,
      pushBatchLimit: pushBatchLimit,
      pullPageLimit: pullPageLimit,
    );
  }

  /// Binds an already-opened metadata store. Applications call [open].
  ///
  /// The store field is private: a public [SembastMetadataStore] member
  /// would leak the engine type even after the class left the barrel.
  UlsyncClient._({
    required this.baseUrl,
    required String origin,
    required String userScope,
    required String sourceId,
    required this.tokenProvider,
    required this._store,
    required List<EntityAdapter<dynamic>> adapters,
    SyncTransport? transport,
    this.beforePersistIncoming,
    Duration catchUpRetryDelay = const Duration(seconds: 1),
    required this._nowMs,
    required this._clockOffsetMs,
    required this._clockSampled,
    int pushBatchLimit = kPushBatchLimit,
    int pullPageLimit = kPullPageLimit,
  }) : origin = requireUlsyncOrigin(origin),
       userScope = _requireNonEmpty(userScope, 'userScope'),
       sourceId = _requireNonEmpty(sourceId, 'sourceId'),
       _adapters = _indexAdapters(adapters),
       // ignore: prefer_initializing_formals
       _catchUpRetryDelay = catchUpRetryDelay,
       _pushBatchLimit = _requireSpecBatchLimit(
         pushBatchLimit,
         'pushBatchLimit',
       ),
       _pullPageLimit = _requireSpecBatchLimit(pullPageLimit, 'pullPageLimit'),
       _transport =
           transport ??
           HttpSyncTransport(
             baseUrl: baseUrl,
             tokenProvider: tokenProvider,
             origin: origin,
           );

  /// Server URL. Ignored when a [SyncTransport] is injected.
  final Uri baseUrl;

  /// Application-contour origin sent as `Ulsync-Origin`.
  ///
  /// Minted once per application contour in the application project, never
  /// per device. Ignored by non-HTTP test doubles (they do not send
  /// headers).
  final String origin;

  /// Signed-in user; part of every metadata key so accounts never mix.
  final String userScope;

  /// Stable installation id written to envelope `source_id`.
  final String sourceId;

  /// Supplies the bearer token before every HTTP call, including 401 retry.
  final Future<String?> Function() tokenProvider;

  /// Metadata database: cursor, dirty queue, revision. Not entity payloads.
  ///
  /// Private so the sembast type cannot leak through a public member after
  /// the class left the barrel. Applications never see this field.
  final SembastMetadataStore _store;

  /// Adapters keyed by `entity_type`. Lookups use this map, never `dynamic`.
  final Map<String, EntityAdapter<dynamic>> _adapters;

  /// Transport in use; created here when the caller did not inject one.
  final SyncTransport _transport;

  /// Test-only seam between application `apply` and metadata persist.
  ///
  /// Runs after [EntityAdapter.apply] and before the metadata write. There
  /// is no store interface (triad plan §13.9); this hook is that crash
  /// window. Production callers omit it. README and the example do not
  /// mention it.
  final Future<void> Function()? beforePersistIncoming;

  /// Pause between catch-up [syncOnce] attempts after a transport miss.
  ///
  /// Used after live restore, [notifyResumed], and a local edit while
  /// [live] is running. The engine keeps trying until the server answers
  /// or [close]. A 4xx ([UlsyncUnauthorized], [UlsyncRequestRejected])
  /// stops the loop: the request is wrong, not "server down".
  final Duration _catchUpRetryDelay;

  /// Test hatch for the device clock. Production uses [_systemNowMs].
  final int Function() _nowMs;

  /// `server_now_ms − nowMs` at the last sample. Zero before a sample.
  int _clockOffsetMs;

  /// Whether a store clock sample has already been applied for this file.
  ///
  /// First sample rewrites dirty rows of [sourceId]. Later samples update
  /// [_clockOffsetMs] and must not restamp the queue.
  bool _clockSampled;

  /// Ceiling for one push. Record kits are packed to fit; they are not cut.
  final int _pushBatchLimit;

  /// Ceiling for one pull page. A full page holds the trailing record kit.
  final int _pullPageLimit;

  /// Applied `server_seq`. Read by [SyncTransport.live]'s `appliedSince`
  /// synchronously — that callback must never call [_store.readCursor].
  int _appliedCursor = 0;

  /// Whether [_appliedCursor] has been loaded from [_store] this session.
  bool _cursorLoaded = false;

  /// Set by [close]; later mutating calls throw [StateError].
  bool _closed = false;

  /// Whether [selfCheck] already completed as part of a successful [syncOnce].
  ///
  /// Set only after the existing [syncOnce] body succeeds. A first exchange
  /// that fails on the network must retry the check, not skip it for the
  /// rest of this client's life. [StateError] from a changed `source_id`
  /// also leaves this false so the next [syncOnce] surfaces the same error.
  bool _selfCheckDone = false;

  /// Whether [selfCheck] (or the [syncOnce] prologue) is on the stack.
  ///
  /// [selfCheck] drains the queue by calling [syncOnce]. Without this flag
  /// that call would recurse. The serial lock is not re-entrant; the drain
  /// must run **outside** [_serialized].
  bool _selfCheckRunning = false;

  /// Whether SPEC section 3.5 hello already succeeded or was unavailable.
  ///
  /// Hello runs before [selfCheck] so a foreign store is refused before
  /// reconciliation can seed it. HTTP `404` is not an error (old server).
  /// [OriginMismatchException] (`409`) must not set this: the next call
  /// repeats the refusal rather than swallow it.
  bool _originChecked = false;

  /// Whether [_ensureOrigin] is on the stack.
  ///
  /// Separate from [_selfCheckRunning]: a successful hello with a failed
  /// self-check must not skip the check, and the reverse must not skip
  /// hello. Hello is not invoked from inside [_serialized].
  bool _originRunning = false;

  /// In-flight hello, so a concurrent [syncOnce] waits instead of racing
  /// past the gate.
  Future<void>? _originInFlight;

  /// Whether [_runLive] has been started. [live] is idempotent.
  bool _liveStarted = false;

  /// Completes when [_runLive] exits; awaited in [close] before store close.
  Future<void>? _liveDone;

  /// In-flight catch-up after restore, a local edit, or [notifyResumed].
  ///
  /// One loop at a time. A kick that arrives while this is set must not
  /// start a second HTTP exchange; it sets [_catchUpPending] so the
  /// running loop drains the newer revision after the in-flight POST.
  Completer<void>? _catchUpGate;

  /// Whether another catch-up kick arrived while [_catchUpGate] was held.
  ///
  /// Without this, a [write] during a hanging POST joins the in-flight
  /// loop, that loop's [syncOnce] succeeds without posting the new
  /// revision, and dirty sits until the next user gesture. Mute does not
  /// set this: [_scheduleCatchUpAfterLocalEdit] does not run unless
  /// [_liveStarted] is true.
  bool _catchUpPending = false;

  /// Outward events. Broadcast so a late subscriber does not throw; events
  /// with no listener are dropped (subscribe before [syncOnce] if you need
  /// pull-time events).
  final StreamController<SyncEvent> _events =
      StreamController<SyncEvent>.broadcast();

  /// Mutex tail. Each [_serialized] call waits for this, then replaces it.
  ///
  /// Covers [markChanged], the whole of [write] and [writeAll] including
  /// every persist callback, the **snapshot** of a push batch and the
  /// **clear** of dirty after HTTP returns, pull/live **ingest** of one
  /// page or one live message, and domain reconcile — not the live
  /// subscription itself, and **not** HTTP push or pull. Holding the lock
  /// across `_transport.push` / `pull` would make the next [write] wait
  /// on [kPushPullTimeout] (30s): that is a pause of input, not of
  /// exchange. Holding the lock for the lifetime of [live] would make
  /// [syncOnce] wait forever. Releasing it between the dirty mark of
  /// [write] and persist would let [syncOnce] clear the mark after `load`
  /// returned `null`. Releasing it between items of [writeAll] would let
  /// the live feed POST the first rows of a related edit.
  Future<void> _tail = Future<void>.value();

  /// Records a local edit: bumps revision, sets dirty, writes metadata.
  ///
  /// **Low-level primitive.** Prefer [write], which marks the record
  /// *before* the application persist callback and holds the serial lock
  /// for the whole callback. Calling this *after* a local write can lose
  /// the record forever: a crash, an unawaited future, or a skipped call
  /// leaves application data with no dirty mark, and nothing ever sends
  /// it. Use this only when the application cannot persist through the
  /// library (for example a later self-check pass).
  ///
  /// [part] names the envelope cell. Default [kEnvelopePart] (`full`).
  /// The mark is keyed `(id, part)` the same way metadata already is.
  /// Each cell belongs to an **indivisible, complete** kit: marking
  /// `full` does not stand in for `done`. A blank value after trim is
  /// [ArgumentError]. This method does not require
  /// [EntityAdapter.encodePart]: it is the primitive that can mark a
  /// slice the next push will refuse to encode. Prefer [write], which
  /// throws [StateError] before marking when the encoder is missing.
  ///
  /// This future returns after the metadata persist. It does not wait for
  /// the network and does not throw [UlsyncNetworkException]. If [live]
  /// has been started, the engine schedules catch-up; the application
  /// does not call [syncOnce] after each mark. If [live] has not been
  /// started, this is Work-offline mute: push is not invoked.
  ///
  /// The engine owns the revision. The application must not mint it: a stale
  /// number loses a last-write-wins tie and the edit disappears silently.
  /// Throws [ArgumentError] when no adapter is registered for [entityType]
  /// (the store is not touched). Throws [StateError] after [close], or when
  /// called from inside the persist callback of [write] or [writeAll].
  Future<void> markChanged({
    required String entityType,
    required String id,
    String part = kEnvelopePart,
  }) async {
    _ensureOpen();
    final trimmedPart = _requireNonEmpty(part, 'part');
    await _serialized(() async {
      _ensureOpen();
      final adapter = _adapters[entityType];
      if (adapter == null) {
        throw ArgumentError.value(
          entityType,
          'entityType',
          'no adapter registered',
        );
      }
      await _markChangedLocked(
        entityType: entityType,
        id: id,
        adapter: adapter,
        part: trimmedPart,
      );
    });
    _scheduleCatchUpAfterLocalEdit();
  }

  /// Records a local edit and returns after [persist] finishes.
  ///
  /// This future does not wait for the network and does not throw
  /// [UlsyncNetworkException]. The dirty mark is already stored. If [live]
  /// has been started, the engine schedules catch-up; the application does
  /// not call [syncOnce] after each edit. If [live] has not been started,
  /// this is Work-offline mute: push is not invoked.
  ///
  /// The dirty mark is written **before** [persist] runs. The two stores
  /// (library metadata and the application's database) cannot share a
  /// transaction, so a crash in the middle must choose a side: a mark
  /// without data is healed on the next push (`load` or
  /// [EntityAdapter.encodePart] returns `null` and the engine clears
  /// dirty). Data without a mark is a silent permanent loss. That is why
  /// the order is not reversed even when "write the row first" looks more
  /// natural.
  ///
  /// [part] names the envelope cell. Default [kEnvelopePart] (`full`).
  /// Identity is `(id, part)`: a checkbox and a hide flag on the same
  /// record are two cells of one **indivisible, complete** kit, and
  /// last-write-wins does not cross between them. A blank value after
  /// trim is [ArgumentError]. When [part] is not `full` and the adapter
  /// has no [EntityAdapter.encodePart], this throws [StateError]
  /// **before** the mark so [persist] does not run and an unsendable row
  /// is not left behind.
  ///
  /// The same serial lock covers [persist]. Releasing it between the mark
  /// and the application write would let a concurrent drain observe
  /// dirty, load `null`, and clear the mark — the loss this method exists
  /// to prevent. HTTP push/pull do **not** hold that lock: a second
  /// [write] must finish in persist time, not in the 30-second transport
  /// timeout.
  ///
  /// Do not call [UlsyncClient] methods from [persist]. That would wait on
  /// this lock forever. The engine throws a [StateError] instead of hanging.
  /// Write only application data there.
  ///
  /// Returns whatever [persist] returns. If [persist] throws, the error is
  /// rethrown as-is, the dirty mark remains, and catch-up is not scheduled
  /// from this call.
  ///
  /// Throws [ArgumentError] when no adapter is registered for [entityType]
  /// (the store is not touched, [persist] does not run). Throws [StateError]
  /// after [close], or when called from inside another [write] or [writeAll]
  /// persist callback.
  Future<T> write<T>({
    required String entityType,
    required String id,
    required Future<T> Function() persist,
    String part = kEnvelopePart,
  }) async {
    _ensureOpen();
    final trimmedPart = _requireNonEmpty(part, 'part');
    final result = await _serialized(() async {
      _ensureOpen();
      return _writeOneLocked(
        entityType: entityType,
        id: id,
        part: trimmedPart,
        persist: persist,
      );
    });
    _scheduleCatchUpAfterLocalEdit();
    return result;
  }

  /// Applies several [write] operations under the same lock as a single [write].
  ///
  /// Use this for one user action that touches many rows ("move done to trash").
  /// This future returns after every persist in [ops] finishes. It does not
  /// wait for the network and does not throw [UlsyncNetworkException]. Live
  /// ingest waits until every persist finished, so the feed cannot POST the
  /// first five while the rest are still being marked. Each [WriteOp.part] is
  /// one cell of an **indivisible** kit: `full` and `deleted` of the same id
  /// must both be marked if both changed; the send queue will not split that
  /// kit at the SPEC ceiling.
  ///
  /// If [live] has been started, the engine schedules catch-up after persist;
  /// the application does not call [syncOnce] after the related edit. If
  /// [live] has not been started, this is Work-offline mute: push is not
  /// invoked.
  ///
  /// An empty list is a no-op, not an error, and does not schedule catch-up.
  /// If persist of item 5 throws, items 1–5 are marked dirty and 6…N have
  /// not started — the same contract as a throwing single [write]. This
  /// method does not open a database transaction across the application
  /// store and the metadata store: those are two files.
  ///
  /// Each item is checked, marked, and persisted in list order, with the same
  /// adapter and [EntityAdapter.encodePart] rules as [write]. Do not call
  /// [UlsyncClient] methods from [WriteOp.persist].
  ///
  /// Throws [ArgumentError] when an item names an unknown [WriteOp.entityType]
  /// or a blank [WriteOp.part]. Throws [StateError] after [close], when called
  /// from inside a persist callback, or when a named part has no encoder.
  Future<void> writeAll(List<WriteOp> ops) async {
    if (ops.isEmpty) {
      return;
    }
    _ensureOpen();
    await _serialized(() async {
      _ensureOpen();
      for (final op in ops) {
        await _writeOneLocked(
          entityType: op.entityType,
          id: op.id,
          part: _requireNonEmpty(op.part, 'part'),
          persist: op.persist,
        );
      }
    });
    _scheduleCatchUpAfterLocalEdit();
  }

  /// Marks one row and runs [persist] while the caller already holds
  /// [_serialized].
  ///
  /// Shared by [write] and [writeAll] so a related edit cannot skip the
  /// encode-part guard or release the lock between items. The dirty mark
  /// is written before entering the persist zone so this method's own
  /// [_serialized] wait is not treated as re-entry.
  Future<T> _writeOneLocked<T>({
    required String entityType,
    required String id,
    required String part,
    required Future<T> Function() persist,
  }) async {
    final adapter = _adapters[entityType];
    if (adapter == null) {
      throw ArgumentError.value(
        entityType,
        'entityType',
        'no adapter registered',
      );
    }
    if (part != kEnvelopePart && adapter.encodePart == null) {
      throw StateError(
        'EntityAdapter.encodePart is required to write part '
        '"$part"; without it the engine would mark a row it '
        'cannot encode. The persist callback did not run.',
      );
    }
    await _markChangedLocked(
      entityType: entityType,
      id: id,
      adapter: adapter,
      part: part,
    );
    return await runZoned(persist, zoneValues: {_writeZoneKey: true});
  }

  /// Writes a dirty metadata row for ([id], [part]). Caller already holds
  /// [_serialized].
  ///
  /// Shared by [markChanged], [write], and [writeAll] so the public marks cannot
  /// drift. [adapter] is already resolved; this method does not look it up.
  /// [part] is the trimmed cell name; last-write-wins and the send queue
  /// both key this row, not a neighbour with the same [id]. After a store
  /// clock sample the stamp is [_correctedNowMs], not raw device time: a
  /// fast board must not beat a later real edit. The server does not
  /// rewrite incoming `last_edited_at_ms`; this method is the only place
  /// that sets outgoing ranks for a local edit.
  Future<void> _markChangedLocked({
    required String entityType,
    required String id,
    required EntityAdapter<dynamic> adapter,
    required String part,
  }) async {
    final existing = await _store.stateOf(
      userScope: userScope,
      entityType: entityType,
      id: id,
      part: part,
    );
    final now = _correctedNowMs();
    await _store.put(
      EntityState(
        userScope: userScope,
        entityType: entityType,
        id: id,
        part: part,
        createdAtMs: existing?.createdAtMs ?? now,
        lastEditedAtMs: now,
        revision: (existing?.revision ?? 0) + 1,
        sourceId: sourceId,
        schemaVersion: adapter.schemaVersion,
        dirty: true,
      ),
    );
  }

  /// Finds and repairs divergence without asking where it came from.
  ///
  /// Runs three phases in order: installation identity, the application's data
  /// against library metadata, and library metadata against the server. Each
  /// phase reports whether it was available; an unavailable phase is a
  /// supported configuration, not an error. The library calls this once per
  /// client on the first [syncOnce] — an application normally never calls it.
  ///
  /// The local phase always invokes [EntityAdapter.listIds]. It reports
  /// unavailable only when this client has no adapters. When
  /// [includeServer] is `false`, or the transport does not implement
  /// [SyncDiffTransport], or the server answers 404/405, the server phase
  /// reports unavailable. An old server is a supported configuration.
  ///
  /// Marking a row the library already knows **does not change** its edit
  /// time, creation time, or revision. Those are the ranks of SPEC section 2;
  /// refreshing them would let a stale local copy defeat a newer copy from
  /// another device.
  ///
  /// A record the library has never seen is created with time `1` and
  /// revision `1`. One millisecond after epoch is older than any real edit,
  /// so a copy from another device still wins. Zero cannot go on the wire:
  /// the server rejects `created_at_ms <= 0`.
  ///
  /// Throws [StateError] when the stored `source_id` does not match this
  /// client's, after [close], or when called from inside [write]'s persist
  /// callback. The identity error names both values; restore the previous
  /// id or delete the metadata database. It is not a network glitch.
  Future<SelfCheckReport> selfCheck({bool includeServer = true}) async {
    _ensureOpen();
    // Already true when [syncOnce] is the caller: skip drain so the existing
    // [syncOnce] body is the one push/pull. Direct calls drain themselves.
    final fromPrelude = _selfCheckRunning;
    _selfCheckRunning = true;
    try {
      await _serialized(_checkInstallationIdentity);
      final local = await _serialized(_reconcileLocalIds);
      final server = await _reconcileWithServer(includeServer: includeServer);
      if (!fromPrelude) {
        await _drainDirtyQueue();
      }
      final remaining = await _dirtyCount();
      return SelfCheckReport(
        localAvailable: local.available,
        localMarked: local.marked,
        serverAvailable: server.available,
        serverProbed: server.probed,
        serverMissing: server.missing,
        serverStale: server.stale,
        serverMarked: server.marked,
        remainingDirty: remaining,
      );
    } finally {
      if (!fromPrelude) {
        _selfCheckRunning = false;
      }
    }
  }

  /// Pushes the dirty queue, then pulls until a short page.
  ///
  /// Public method for first sign-in, leaving Work-offline mute, and tests.
  /// With [live] running the application does **not** retry a store outage
  /// by calling this after each edit or from [SyncConnectionLost] /
  /// [SyncConnectionRestored]: the engine already catch-up-retries. A
  /// formula that "there is no retry timer, so the application calls this
  /// again" would put the drain back on author memory.
  ///
  /// Push posts **complete, indivisible** record kits: `full` and every
  /// named part of one id travel in the same POST, even when that leaves
  /// the request shorter than [kSpecBatchLimit]. Pull holds a trailing kit
  /// on a full page so the set is not cut at the ceiling. On the first
  /// successful call of this instance, names [origin] to the server
  /// ([_ensureOrigin]) and then runs [selfCheck] (identity, local ids,
  /// server diff). Hello is first because self-check would otherwise seed
  /// a foreign store. The existing push/pull body is the drain for marks
  /// the check just made. Neither hello nor [selfCheck] is invoked from
  /// inside [_serialized] — the lock is not re-entrant, and that call
  /// would hang forever.
  ///
  /// HTTP push and pull run **outside** [_serialized]. The batch snapshot
  /// (load, encode, pack) is under the lock; the POST is not; dirty is
  /// cleared under the lock only when the stored `(id, part, revision)`
  /// still matches the snapshot. Clearing "everything we tried to send"
  /// would drop a [write] of the same cell that landed while the POST was
  /// in flight. Pull ingest of one page stays serialized with persist, as
  /// does one live message, so the feed cannot POST half of a [writeAll].
  ///
  /// Before pull, the engine **auto-heals** when the stored cursor is ahead
  /// of the server feed head (see README, *Local metadata*). A network or
  /// HTTP `5xx` error is thrown; `dirty` stays set. Catch-up retries those
  /// errors. `4xx` ([UlsyncUnauthorized], [UlsyncRequestRejected]) stops
  /// catch-up: the request is wrong, not "server down".
  ///
  /// `applied: false` still clears dirty when the revision still matches:
  /// the server already holds a non-inferior row (SPEC section 7). Leaving
  /// dirty set retries forever.
  Future<SyncReport> syncOnce() async {
    _ensureOpen();
    await _ensureOrigin();
    _ensureOpen();
    final Future<void> prelude;
    if (!_selfCheckDone && !_selfCheckRunning) {
      _selfCheckRunning = true;
      prelude = () async {
        try {
          await selfCheck();
        } finally {
          _selfCheckRunning = false;
        }
      }();
    } else {
      prelude = Future<void>.value();
    }
    return prelude
        .then((_) async {
          _ensureOpen();
          final counters = _SyncCounters();
          await _pushDirty(counters);
          await _serialized(() async {
            _ensureOpen();
            await _ensureCursorLoaded();
            await _reconcileDomainBehindMetadata();
          });
          await _reconcileCursorIfAhead();
          await _pullPages(counters);
          return SyncReport(
            pushed: counters.pushed,
            accepted: counters.accepted,
            pulled: counters.pulled,
            applied: counters.applied,
            cursor: _appliedCursor,
          );
        })
        .then((report) {
          if (!_selfCheckRunning) {
            _selfCheckDone = true;
          }
          return report;
        });
  }

  /// Returns the outbound event stream and starts the live worry loop.
  ///
  /// Call this **once** after sign-in. The engine then reopens the feed
  /// on its own until [close]. Hello and HTTP start on a later microtask
  /// after [_ensureOrigin]. The applied cursor is loaded and auto-healed
  /// when ahead of the server feed head. Reopens call `appliedSince`
  /// again and see the cursor as of **now**, not as of the first [live]
  /// call. Later [write] calls schedule catch-up; this method does not
  /// start [live] from [write], and [write] does not start [live].
  ///
  /// This does **not** replace [notifyResumed]. A frozen isolate still
  /// looks connected until the application reports a wake.
  Stream<SyncEvent> live() {
    _ensureOpen();
    if (!_liveStarted) {
      _liveStarted = true;
      _liveDone = _runLive();
    }
    return _events.stream;
  }

  /// Reports that this isolate is running in the foreground again.
  ///
  /// This is the **only** lifecycle kick the application owes the engine.
  /// `lib/` must not import Flutter, so [UlsyncClient] cannot observe
  /// `AppLifecycleState`. A suspended isolate does not run Dart timers:
  /// the live silence watchdog sleeps, and a half-open TCP socket can
  /// still look healthy. The engine sees a store TCP drop on its own and
  /// catch-up-retries; it cannot see isolate sleep. Without this call,
  /// catch-up waits until that watchdog (45s after the isolate actually
  /// runs again).
  ///
  /// Call from `WidgetsBindingObserver.didChangeAppLifecycleState` when
  /// the state is `AppLifecycleState.resumed` (lock screen, app switcher,
  /// laptop sleep, first frame after a killed isolate). Tests call it
  /// when their host wakes. Do **not** call it on every [SyncEvent]; the
  /// engine already catch-up-retries after [SyncConnectionRestored] and
  /// after a local [write] while [live] is running.
  ///
  /// Drops the current live body immediately ([SyncTransport.pokeLive]),
  /// then runs [syncOnce] until push/pull succeed or [close]. Network
  /// and HTTP `5xx` retry with backoff. [UlsyncUnauthorized] and other
  /// 4xx stop the loop: the token or request is wrong.
  Future<void> notifyResumed() async {
    _ensureOpen();
    await _transport.pokeLive();
    await _catchUpUntilReachable();
  }

  /// Stops live ingest, then closes transport and store.
  ///
  /// A second call is a no-op. Later [write], [writeAll], [markChanged], [selfCheck],
  /// [syncOnce], or [live] throw [StateError] with `UlsyncClient is closed`. Transport is
  /// closed before the store so a last ingest cannot persist into a closed
  /// database and look like a metadata bug.
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _transport.close();
    final liveDone = _liveDone;
    if (liveDone != null) {
      await liveDone;
    }
    await _serialized(() async {});
    await _store.close();
    if (!_events.isClosed) {
      await _events.close();
    }
  }

  /// Names [origin] to the server before any mail or [selfCheck].
  ///
  /// Hello is first because self-check would seed a foreign store. HTTP
  /// `404`/`405` means the endpoint is absent, not a mismatch. `409` does
  /// not set [_originChecked]: the next call must repeat the refusal.
  /// Runs outside [_serialized] so it cannot deadlock the lock.
  Future<void> _ensureOrigin() async {
    if (_originChecked) {
      assert(!_originRunning);
      return;
    }
    final inFlight = _originInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    _originRunning = true;
    final future = _runOriginHandshake();
    _originInFlight = future;
    try {
      await future;
    } finally {
      _originRunning = false;
      if (identical(_originInFlight, future)) {
        _originInFlight = null;
      }
    }
  }

  /// One hello attempt. Sets [_originChecked] only on success or unavailability.
  ///
  /// Hello runs outside [_serialized]. A non-null `server_now_ms` is
  /// applied under the lock after the HTTP returns so dirty restamp cannot
  /// race a [write] and cannot run during the round-trip.
  Future<void> _runOriginHandshake() async {
    final candidate = _transport;
    HelloResult? result;
    if (candidate is SyncHelloTransport) {
      // Separate interface; the `is` check does not promote a SyncTransport.
      final helloTransport = candidate as SyncHelloTransport;
      result = await helloTransport.hello(origin);
    }
    _originChecked = true;
    await _applyClockSample(result?.serverNowMs);
  }

  /// Unix milliseconds used to stamp a local edit.
  ///
  /// Before the first `server_now_ms` sample this is [_nowMs]. After a
  /// sample it is [_nowMs] plus the stored offset so last-write-wins
  /// compares devices in store time, not by which board runs fast.
  /// Completeness of sync is still `server_seq`; this value does not hide
  /// rows. The application does not supply [_nowMs] in production.
  int _correctedNowMs() {
    final raw = _nowMs();
    if (!_clockSampled) {
      return raw;
    }
    return raw + _clockOffsetMs;
  }

  /// Applies [serverNowMs] under [_serialized] when the value is present.
  ///
  /// Must not be called from inside [_serialized]: the lock is not
  /// re-entrant. Pull ingest and live cursor call
  /// [_applyClockSampleLocked] instead. Hello and the feed-head probe
  /// run HTTP outside the lock, then this method.
  Future<void> _applyClockSample(int? serverNowMs) {
    if (serverNowMs == null) {
      return Future<void>.value();
    }
    return _serialized(() => _applyClockSampleLocked(serverNowMs));
  }

  /// Records offset = `serverNowMs − nowMs` and, on the first sample,
  /// restamps dirty rows of [sourceId].
  ///
  /// Caller already holds [_serialized]. HTTP must already have returned.
  /// A repeat sample updates [_clockOffsetMs] and does not rewrite dirty:
  /// a queue that was already shifted would jump again. Foreign
  /// `source_id` and incoming envelopes are not written here — those ranks
  /// arrived on the wire. [SembastMetadataStore.markDirty] still does not
  /// change clocks: a self-check that stamped "now" would let a stale
  /// local copy beat a newer neighbour.
  Future<void> _applyClockSampleLocked(int? serverNowMs) async {
    if (serverNowMs == null) {
      return;
    }
    _ensureOpen();
    final offsetMs = serverNowMs - _nowMs();
    final firstSample = !_clockSampled;
    await _store.persistClockSample(
      userScope: userScope,
      sourceId: sourceId,
      offsetMs: offsetMs,
      rewriteDirty: firstSample,
    );
    _clockOffsetMs = offsetMs;
    _clockSampled = true;
  }

  /// Runs [action] after the previous serialized job, even if that job failed.
  ///
  /// [_tail] is a [Completer] completed in `whenComplete`, not the action's
  /// own future, so one error does not stall the queue.
  ///
  /// The first line rejects re-entry from a [write] or [writeAll] persist
  /// callback. Nested [UlsyncClient] calls would wait on this lock forever;
  /// a [StateError] is louder than a hang in a sync library.
  Future<T> _serialized<T>(Future<T> Function() action) {
    if (Zone.current[_writeZoneKey] == true) {
      throw StateError(
        'do not call UlsyncClient methods inside the persist callback; '
        'write only application data there',
      );
    }
    final previous = _tail;
    late final Completer<void> gate;
    gate = Completer<void>();
    _tail = gate.future;
    return previous.then((_) => action()).whenComplete(() {
      if (!gate.isCompleted) {
        gate.complete();
      }
    });
  }

  /// Throws [StateError] when [close] has already run.
  void _ensureOpen() {
    if (_closed) {
      throw StateError('UlsyncClient is closed');
    }
  }

  /// Phase 1: persist `source_id` on first open, refuse a silent swap.
  ///
  /// The third rank of SPEC section 2 is the only tiebreaker when time and
  /// revision match. Two installations that share one `source_id` diverge
  /// forever with no later check able to see it (SPEC section 1.4). A
  /// changed id is therefore a loud [StateError], not a log line.
  Future<void> _checkInstallationIdentity() async {
    final stored = await _store.readSourceId(userScope);
    if (stored == null) {
      await _store.writeSourceId(userScope, sourceId);
      return;
    }
    if (stored == sourceId) {
      return;
    }
    throw StateError(
      'ulsync source_id for user scope "$userScope" changed: '
      'stored "$stored", current "$sourceId". '
      'Restore the previous installation id, or if the change is '
      'intentional, delete the library metadata database.',
    );
  }

  /// Phase 2: application ids vs metadata. Time `1` means unknown age.
  Future<({bool available, int marked})> _reconcileLocalIds() async {
    if (_adapters.isEmpty) {
      return (available: false, marked: 0);
    }
    var marked = 0;
    for (final adapter in _adapters.values) {
      final ids = await adapter.listIds();
      for (final id in ids) {
        final existing = await _store.stateOf(
          userScope: userScope,
          entityType: adapter.entityType,
          id: id,
          part: kEnvelopePart,
        );
        if (existing != null) {
          continue;
        }
        // Unknown to the library. Time 1 is older than any real edit and is
        // legal on the wire (the server rejects 0).
        await _store.put(
          EntityState(
            userScope: userScope,
            entityType: adapter.entityType,
            id: id,
            part: kEnvelopePart,
            createdAtMs: 1,
            lastEditedAtMs: 1,
            revision: 1,
            sourceId: sourceId,
            schemaVersion: adapter.schemaVersion,
            dirty: true,
          ),
        );
        marked++;
      }
    }
    return (available: true, marked: marked);
  }

  /// Phase 3: metadata vs server. The server compares; the client only marks.
  ///
  /// Dirty rows are already on the send queue, so they are not probed: the
  /// coming push is the repair. The request still carries the full three
  /// ranks for every clean row — comparing by revision alone would miss a
  /// later client edit at equal or lower revision (SPEC section 3.4).
  Future<({bool available, int probed, int missing, int stale, int marked})>
  _reconcileWithServer({required bool includeServer}) async {
    const unavailable = (
      available: false,
      probed: 0,
      missing: 0,
      stale: 0,
      marked: 0,
    );
    if (!includeServer) {
      return unavailable;
    }
    final candidate = _transport;
    if (candidate is! SyncDiffTransport) {
      return unavailable;
    }
    // Unrelated to [SyncTransport]; the `is` check does not promote.
    final diffTransport = candidate as SyncDiffTransport;
    final collected = await _serialized(() async {
      final states = await _store.allStates(userScope);
      final types = <String, String>{};
      final probes = <DiffProbe>[];
      for (final row in states) {
        types['${row.id}\u0000${row.part}'] = row.entityType;
        if (row.dirty) {
          continue;
        }
        probes.add(
          DiffProbe(
            id: row.id,
            part: row.part,
            lastEditedAtMs: row.lastEditedAtMs,
            revision: row.revision,
            sourceId: row.sourceId,
          ),
        );
      }
      return (types: types, probes: probes);
    });
    if (collected.probes.isEmpty) {
      return (available: true, probed: 0, missing: 0, stale: 0, marked: 0);
    }
    final verdicts = <DiffVerdict>[];
    var probed = 0;
    final chunks = packCompleteDiffKits(
      collected.probes,
      limit: kDiffBatchLimit,
    );
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final batch = await diffTransport.diff(chunk);
      if (batch == null) {
        if (i == 0) {
          return unavailable;
        }
        break;
      }
      probed += chunk.length;
      verdicts.addAll(batch);
    }
    var missing = 0;
    var stale = 0;
    var marked = 0;
    await _serialized(() async {
      for (final verdict in verdicts) {
        switch (verdict.gap) {
          case DiffGap.missing:
            missing++;
          case DiffGap.stale:
            stale++;
        }
        final entityType =
            collected.types['${verdict.id}\u0000${verdict.part}'];
        if (entityType == null) {
          continue;
        }
        // Clock stays: this is not an edit. Refreshing lastEditedAtMs here
        // would let this device's stale copy win SPEC section 2.
        final ok = await _store.markDirty(
          userScope: userScope,
          entityType: entityType,
          id: verdict.id,
          part: verdict.part,
        );
        if (ok) {
          marked++;
        }
      }
    });
    return (
      available: true,
      probed: probed,
      missing: missing,
      stale: stale,
      marked: marked,
    );
  }

  /// Runs [syncOnce] until the dirty queue stops shrinking. Outside the lock.
  Future<void> _drainDirtyQueue() async {
    var remaining = await _dirtyCount();
    while (remaining > 0) {
      await syncOnce();
      final next = await _dirtyCount();
      if (next >= remaining) {
        break;
      }
      remaining = next;
    }
  }

  /// Dirty rows in this [userScope].
  Future<int> _dirtyCount() async {
    final states = await _store.allStates(userScope);
    var n = 0;
    for (final row in states) {
      if (row.dirty) {
        n++;
      }
    }
    return n;
  }

  /// Loads [_appliedCursor] from [_store] once per client lifetime.
  Future<void> _ensureCursorLoaded() async {
    if (_cursorLoaded) {
      return;
    }
    _appliedCursor = await _store.readCursor(userScope);
    _cursorLoaded = true;
  }

  /// Server feed head from paginated `pull(since: 0)`; `0` when the feed is empty.
  Future<int> _probeFeedHead() async {
    var since = 0;
    while (true) {
      _ensureOpen();
      final page = await _transport.pull(since: since, limit: _pullPageLimit);
      await _applyClockSample(page.serverNowMs);
      if (page.envelopes.length < _pullPageLimit) {
        return page.nextCursor;
      }
      if (page.nextCursor <= since) {
        return page.nextCursor;
      }
      since = page.nextCursor;
    }
  }

  /// Replays the feed when library metadata remembers rows the app does not.
  ///
  /// The metadata file can outlive the in-memory domain: process restart, or
  /// an application that clears its store on sign-in while keeping the same
  /// [name]. A cursor already at the feed head makes [pull] return nothing
  /// while [EntityAdapter.load] returns `null` for those ids. **Every**
  /// stored cell counts — a kit is **complete** only as the union of `full`
  /// and every named part; `done` / `deleted` are not optional footnotes.
  /// Resetting the cursor and replaying is safe because apply is
  /// idempotent.
  Future<void> _reconcileDomainBehindMetadata() async {
    if (_adapters.isEmpty) {
      return;
    }
    final states = await _store.allStates(userScope);
    for (final row in states) {
      final adapter = _adapters[row.entityType];
      if (adapter == null) {
        continue;
      }
      if (await adapter.load(row.id) == null) {
        await _store.resetCursor(userScope);
        _appliedCursor = 0;
        return;
      }
    }
  }

  /// Resets local cursor when metadata is ahead of the server feed.
  ///
  /// After a server-side store reset, clients can keep a high sembast cursor
  /// and skip live catch-up. The server is read-only here: replay from
  /// `since=0` and idempotent [EntityAdapter.apply] realign the client.
  /// The feed-head probe is HTTP and must not hold [_serialized]; only the
  /// cursor read and the reset do.
  Future<void> _reconcileCursorIfAhead() async {
    final local = await _serialized(() async {
      _ensureOpen();
      await _ensureCursorLoaded();
      return _appliedCursor;
    });
    if (local == 0) {
      return;
    }
    final head = await _probeFeedHead();
    if (local <= head) {
      return;
    }
    await _serialized(() async {
      await _store.resetCursor(userScope);
      _appliedCursor = 0;
    });
  }

  /// Sends one complete-kit push, at most [_pushBatchLimit] envelopes.
  ///
  /// Dirty rows are packed so `full` and every named part of one id are an
  /// **indivisible, complete** kit in the same POST. The request may be
  /// shorter than the SPEC ceiling; filling 500 by dropping the rest of a
  /// kit is forbidden. Dirty marks of posted rows are not cleared before
  /// that call returns.
  /// A thrown transport error (including HTTP 413) leaves every posted row
  /// dirty so the next drain retries the same related edit. Clearing a
  /// prefix on the way in would drop half a [writeAll] after a dropped
  /// connection — the hole this method exists to close.
  ///
  /// Snapshot (pack, load, encode) runs under [_serialized]. HTTP
  /// `_transport.push` runs **outside** the lock so a parallel [write]
  /// finishes in persist time, not in the transport timeout. After `200`,
  /// dirty is cleared under the lock only when the cell is still dirty and
  /// [EntityState.revision] still equals the posted snapshot. Clearing
  /// "everything we tried to send" would drop a revision that landed while
  /// the POST was in flight.
  ///
  /// Rows with no adapter, or whose load / [EntityAdapter.encodePart]
  /// returns `null`, are cleared without entering the POST — the same skip
  /// as a single-row drain. They are not in [PushResult] lists and are not
  /// rolled back if the POST later throws.
  ///
  /// [PushResult] length must match the request, and index *i* must name
  /// envelope *i* (`id` and `part`). Otherwise this throws
  /// [UlsyncProtocolException] and does not clear posted marks. After one
  /// successful response, both `applied: true` and `applied: false` clear
  /// dirty when the revision still matches (SPEC section 7).
  ///
  /// HTTP 413 is [UlsyncRequestRejected] like any other 4xx. There is no
  /// second send path that posts the same rows one envelope at a time: a
  /// new client against a server whose limit is still 1 is a named
  /// incompatibility, and two send paths would drift.
  Future<void> _pushDirty(_SyncCounters counters) async {
    final prepared = await _serialized(() async {
      final dirty = await _store.allDirty(userScope);
      final batch = packCompleteRecordKits(dirty, limit: _pushBatchLimit);
      if (batch.isEmpty) {
        return (postedRows: <EntityState>[], envelopes: <Envelope>[]);
      }
      final postedRows = <EntityState>[];
      final envelopes = <Envelope>[];
      for (final row in batch) {
        _ensureOpen();
        final adapter = _adapters[row.entityType];
        if (adapter == null) {
          await _clearDirty(row);
          continue;
        }
        final payload = await _payloadForDirtyRow(row, adapter);
        if (payload == null) {
          await _clearDirty(row);
          continue;
        }
        final createdAtMs = row.createdAtMs <= 0 ? 1 : row.createdAtMs;
        final lastEditedAtMs = row.lastEditedAtMs <= 0 ? 1 : row.lastEditedAtMs;
        postedRows.add(row);
        envelopes.add(
          Envelope(
            id: row.id,
            part: row.part,
            entityType: row.entityType,
            createdAtMs: createdAtMs,
            lastEditedAtMs: lastEditedAtMs,
            revision: row.revision,
            sourceId: row.sourceId,
            flags: kFlags,
            schemaVersion: row.schemaVersion,
            payloadEncoding: kPayloadEncoding,
            payload: payload,
          ),
        );
      }
      return (postedRows: postedRows, envelopes: envelopes);
    });
    if (prepared.envelopes.isEmpty) {
      return;
    }
    final results = await _transport.push(prepared.envelopes);
    _requirePushResultsMatch(prepared.envelopes, results);
    await _serialized(() async {
      _ensureOpen();
      for (var i = 0; i < prepared.postedRows.length; i++) {
        await _clearDirty(prepared.postedRows[i]);
        counters.pushed++;
        if (results[i].applied) {
          counters.accepted++;
        }
      }
    });
  }

  /// Resolves payload bytes for a dirty [row], or `null` when there is
  /// nothing to send.
  ///
  /// [kEnvelopePart] uses [EntityAdapter.load] then [EntityAdapter.encode].
  /// Any other part uses [EntityAdapter.encodePart]. Each is one cell of
  /// an **indivisible** kit; the packer already grouped them. Returning
  /// `null` is the same contract as `load` returning `null`: the caller
  /// clears dirty without POST.
  ///
  /// Throws [StateError] when [row.part] is not `full` and [encodePart] is
  /// missing. [write] already refuses that case before marking; this
  /// guards [markChanged] so an unsendable row cannot be POSTed as a
  /// decoded full snapshot. Dirty is left set so the programming error
  /// is not silently dropped.
  Future<Uint8List?> _payloadForDirtyRow(
    EntityState row,
    EntityAdapter<dynamic> adapter,
  ) async {
    if (row.part == kEnvelopePart) {
      final value = await adapter.load(row.id);
      if (value == null) {
        return null;
      }
      return adapter.encodeValue(value);
    }
    final encodePart = adapter.encodePart;
    if (encodePart == null) {
      throw StateError(
        'EntityAdapter.encodePart is required to push part "${row.part}" '
        'of ${row.entityType}/${row.id}',
      );
    }
    return encodePart(row.id, row.part);
  }

  /// Pulls pages until a short page or a stuck cursor.
  ///
  /// Every ingested envelope is one cell of an **indivisible, complete**
  /// kit. A full page holds the trailing `(entityType, id)` so `full` and
  /// named parts that straddle [_pullPageLimit] are not cut. Applying
  /// `full` does not complete the id.
  ///
  /// HTTP `pull` runs outside [_serialized]. Ingest of the page is under
  /// the lock, same as one live message, so persist of a [writeAll] cannot
  /// interleave with applying half a kit.
  Future<void> _pullPages(_SyncCounters counters) async {
    while (true) {
      _ensureOpen();
      final sinceUsed = _appliedCursor;
      final page = await _transport.pull(
        since: sinceUsed,
        limit: _pullPageLimit,
      );
      final done = await _serialized(() async {
        _ensureOpen();
        await _applyClockSampleLocked(page.serverNowMs);
        if (page.envelopes.isEmpty) {
          await _advanceCursor(page.nextCursor);
          return true;
        }
        final ingestLength = pullIngestLength(page.envelopes, _pullPageLimit);
        for (var i = 0; i < ingestLength; i++) {
          counters.pulled++;
          await _ingest(
            page.envelopes[i],
            countInReport: true,
            counters: counters,
          );
        }
        if (ingestLength == page.envelopes.length) {
          await _advanceCursor(page.nextCursor);
        } else if (_appliedCursor <= sinceUsed) {
          return true;
        }
        if (page.envelopes.length < _pullPageLimit) {
          return true;
        }
        if (page.nextCursor <= sinceUsed) {
          return true;
        }
        return false;
      });
      if (done) {
        break;
      }
    }
  }

  /// Applies one incoming envelope or skips it; always eligible to move cursor.
  ///
  /// `full` and every named part are **equal cells** of one **indivisible,
  /// complete** record kit. The complete row is the union of the set,
  /// applied in feed order (the order those cells were created and
  /// accepted). Last-write-wins compares **only** inside `(id, part)`: a
  /// newer `done` does not beat a local `deleted`, and applying `full`
  /// does not finish the id or license dropping `done` / `deleted`. The
  /// only skip is a **strictly older** version of the **same** cell, so a
  /// newer local edit of that slice is not overwritten. A three-rank tie
  /// still applies — metadata remembering those ranks does not mean the
  /// journal still holds the flags. Completeness forbids treating a tie as
  /// "already applied". Skips and unknown types must **not** call
  /// [SembastMetadataStore.applyIncoming]: that method always writes
  /// [EntityState] and would overwrite a newer local row with an older
  /// envelope.
  ///
  /// `full` uses [EntityAdapter.decode] then [EntityAdapter.apply]. Any
  /// other part uses [EntityAdapter.applyPart]. When [applyPart] is
  /// omitted, the domain is not touched, the cursor still moves, and the
  /// part's metadata is stored so the feed is not replayed forever.
  /// Exchange does not fail: an older build must ignore a slice it does
  /// not understand. Incoming [Envelope.lastEditedAtMs] is stored as it
  /// arrived. The local clock offset must not rewrite a neighbour's rank:
  /// two receivers would otherwise diverge. A stamp in year 2090 still
  /// advances `server_seq`; completeness is the cursor, not the clock.
  Future<void> _ingest(
    Envelope envelope, {
    required bool countInReport,
    _SyncCounters? counters,
  }) async {
    final seq = envelope.serverSeq;
    if (seq == null) {
      throw const UlsyncProtocolException(
        'Incoming envelope missing server_seq',
        field: 'server_seq',
      );
    }
    final adapter = _adapters[envelope.entityType];
    if (adapter == null) {
      await _advanceCursor(seq);
      _emit(SyncUnknownType(entityType: envelope.entityType, id: envelope.id));
      return;
    }
    final local = await _store.stateOf(
      userScope: userScope,
      entityType: envelope.entityType,
      id: envelope.id,
      part: envelope.part,
    );
    if (local != null &&
        incomingIsStale(
          incomingLastEditedAtMs: envelope.lastEditedAtMs,
          incomingRevision: envelope.revision,
          incomingSourceId: envelope.sourceId,
          localLastEditedAtMs: local.lastEditedAtMs,
          localRevision: local.revision,
          localSourceId: local.sourceId,
        )) {
      await _advanceCursor(seq);
      return;
    }
    final wroteDomain = await _applyIncomingDomain(adapter, envelope);
    if (wroteDomain) {
      if (countInReport) {
        counters?.applied++;
      }
      await beforePersistIncoming?.call();
    }
    final now = _nowMs();
    final previousCursor = _appliedCursor;
    await _store.applyIncoming(
      state: EntityState(
        userScope: userScope,
        entityType: envelope.entityType,
        id: envelope.id,
        part: envelope.part,
        createdAtMs: envelope.createdAtMs,
        lastEditedAtMs: envelope.lastEditedAtMs,
        revision: envelope.revision,
        sourceId: envelope.sourceId,
        schemaVersion: envelope.schemaVersion,
        dirty: false,
      ),
      serverSeq: seq,
      atMs: now,
    );
    if (seq > _appliedCursor) {
      _appliedCursor = seq;
    }
    if (wroteDomain) {
      _emit(
        SyncApplied([
          SyncedEntity(entityType: envelope.entityType, id: envelope.id),
        ]),
      );
    }
    if (_appliedCursor > previousCursor) {
      _emit(SyncCursorAdvanced(_appliedCursor));
    }
  }

  /// Writes [envelope] into the application store, or skips the domain.
  ///
  /// Returns `true` when [EntityAdapter.apply] or [EntityAdapter.applyPart]
  /// ran. Returns `false` when [envelope.part] is not `full` and
  /// [applyPart] is omitted: the caller still persists metadata and
  /// advances the cursor. Never compares one part against another: each
  /// cell of the **indivisible** kit is applied on its own.
  Future<bool> _applyIncomingDomain(
    EntityAdapter<dynamic> adapter,
    Envelope envelope,
  ) async {
    final meta = IncomingEnvelopeMeta(
      part: envelope.part,
      createdAtMs: envelope.createdAtMs,
      lastEditedAtMs: envelope.lastEditedAtMs,
      revision: envelope.revision,
      sourceId: envelope.sourceId,
    );
    if (envelope.part == kEnvelopePart) {
      final value = adapter.decode(envelope.payload, envelope.schemaVersion);
      await adapter.applyIncomingValue(value, meta);
      return true;
    }
    final applyPart = adapter.applyPart;
    if (applyPart == null) {
      return false;
    }
    await applyPart(envelope.id, envelope.part, envelope.payload, meta);
    return true;
  }

  /// Moves the persisted cursor forward when [serverSeq] is strictly greater.
  ///
  /// Memory [_appliedCursor] updates only after a successful write. A live
  /// `cursor` event behind the applied value is a no-op (no [SyncCursorAdvanced]).
  Future<void> _advanceCursor(int serverSeq) async {
    final now = _nowMs();
    final moved = await _store.writeCursor(userScope, serverSeq, now);
    if (!moved) {
      return;
    }
    if (serverSeq > _appliedCursor) {
      _appliedCursor = serverSeq;
    }
    _emit(SyncCursorAdvanced(_appliedCursor));
  }

  /// Clears dirty only if [row] is still dirty at [row.revision].
  ///
  /// HTTP is outside [_serialized], so a [write] of the same cell during
  /// the POST bumps revision. Clearing without this match would drop that
  /// edit. [SembastMetadataStore.clearDirty] is the atomic compare.
  Future<void> _clearDirty(EntityState row) {
    return _store.clearDirty(
      userScope: userScope,
      entityType: row.entityType,
      id: row.id,
      part: row.part,
      expectedRevision: row.revision,
    );
  }

  /// Checks that [results] is in request order and names every envelope.
  ///
  /// SPEC section 3.1: `results[i]` is envelope `i`. Length mismatch or a
  /// wrong `(id, part)` at an index is a protocol error; the caller must
  /// not clear dirty. Matching by `id` alone would collapse two parts of
  /// one record into one row.
  void _requirePushResultsMatch(
    List<Envelope> envelopes,
    List<PushResult> results,
  ) {
    if (results.length != envelopes.length) {
      throw UlsyncProtocolException(
        'Push results length ${results.length} does not match '
        'request length ${envelopes.length}',
        field: 'results',
      );
    }
    for (var i = 0; i < envelopes.length; i++) {
      final envelope = envelopes[i];
      final result = results[i];
      if (result.id != envelope.id || result.part != envelope.part) {
        throw UlsyncProtocolException(
          'Push result $i is ${result.id}/${result.part}, '
          'expected ${envelope.id}/${envelope.part}',
          field: 'results',
        );
      }
    }
  }

  /// Opens the live feed. Does not pull first: if the server is down, a pull
  /// would throw and nothing would keep trying. Catch-up is [syncOnce].
  /// Hello runs first so a foreign store cannot apply envelopes on a live
  /// URL miss.
  Future<void> _runLive() async {
    while (!_closed) {
      try {
        await _ensureOrigin();
        if (_closed) {
          return;
        }
        await _serialized(() async {
          await _ensureCursorLoaded();
        });
        if (_closed) {
          return;
        }
        await for (final message in _transport.live(
          appliedSince: () => _appliedCursor,
          onConnectionState: _onConnectionState,
        )) {
          if (_closed) {
            break;
          }
          await _serialized(() => _handleLiveMessage(message));
        }
      } catch (e, st) {
        if (!_closed && !_events.isClosed) {
          _events.add(const SyncConnectionLost());
          _events.addError(e, st);
        }
      }
      if (_closed) {
        return;
      }
      // Transport stream ended without [close]; open the next subscription.
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  /// Applies one live item through the same path as pull.
  Future<void> _handleLiveMessage(LiveMessage message) async {
    _ensureOpen();
    await _ensureCursorLoaded();
    switch (message) {
      case LiveEnvelope(:final envelope):
        await _ingest(envelope, countInReport: false);
      case LiveCursor(:final nextCursor, :final serverNowMs):
        await _applyClockSampleLocked(serverNowMs);
        await _advanceCursor(nextCursor);
      case LiveHeartbeat():
        break;
    }
  }

  /// Forwards transport connection state. Does not take the ingest lock:
  /// it does not write the store.
  void _onConnectionState(LiveConnectionState state) {
    if (_closed || _events.isClosed) {
      return;
    }
    switch (state) {
      case LiveConnectionState.lost:
        _events.add(const SyncConnectionLost());
      case LiveConnectionState.restored:
        _events.add(const SyncConnectionRestored());
        unawaited(_catchUpUntilReachable());
    }
  }

  /// Runs [syncOnce] until the server answers or [close].
  ///
  /// Live reconnect is not enough: envelopes missed while the socket was
  /// down (or while the isolate was frozen) need a pull. Concurrent calls
  /// share one loop. A kick while the loop is in flight sets
  /// [_catchUpPending] so a newer revision written during the POST is
  /// drained after that POST, not left until the next gesture.
  /// [UlsyncUnauthorized] and [UlsyncRequestRejected] stop retrying;
  /// transport and network errors keep trying.
  Future<void> _catchUpUntilReachable() {
    final existing = _catchUpGate;
    if (existing != null) {
      _catchUpPending = true;
      return existing.future;
    }
    final gate = Completer<void>();
    _catchUpGate = gate;
    unawaited(() async {
      try {
        var delay = _catchUpRetryDelay;
        var lastDirty = 1 << 30;
        while (!_closed) {
          _catchUpPending = false;
          try {
            await syncOnce();
            if (_closed) {
              return;
            }
            if (_catchUpPending) {
              lastDirty = 1 << 30;
              continue;
            }
            final remaining = await _dirtyCount();
            if (remaining == 0) {
              return;
            }
            if (remaining >= lastDirty) {
              return;
            }
            lastDirty = remaining;
          } on UlsyncUnauthorized {
            return;
          } on UlsyncRequestRejected {
            return;
          } catch (_) {
            if (_closed) {
              return;
            }
            if (!_events.isClosed) {
              _events.add(const SyncConnectionLost());
            }
            await Future<void>.delayed(delay);
            final next = delay * 2;
            delay = next > const Duration(seconds: 8)
                ? const Duration(seconds: 8)
                : next;
          }
        }
      } finally {
        if (identical(_catchUpGate, gate)) {
          _catchUpGate = null;
        }
        if (!gate.isCompleted) {
          gate.complete();
        }
      }
    }());
    return gate.future;
  }

  /// Starts catch-up after a successful local persist, only if [live] ran.
  ///
  /// Work-offline mute is `close` + `open` without [live]. Scheduling
  /// push from [write] in that state would start talking while the window
  /// is meant to be silent. This must not start [live] itself.
  void _scheduleCatchUpAfterLocalEdit() {
    if (_closed || !_liveStarted) {
      return;
    }
    unawaited(_catchUpUntilReachable());
  }

  /// Adds [event] when the client is still open.
  void _emit(SyncEvent event) {
    if (_closed || _events.isClosed) {
      return;
    }
    _events.add(event);
  }
}

/// Trims [value] and rejects blank identifiers.
String _requireNonEmpty(String value, String name) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(value, name, 'must be non-empty');
  }
  return trimmed;
}

/// Rejects a batch ceiling outside `1…[kSpecBatchLimit]`.
int _requireSpecBatchLimit(int value, String name) {
  if (value < 1 || value > kSpecBatchLimit) {
    throw ArgumentError.value(
      value,
      name,
      'must be an integer in 1…$kSpecBatchLimit',
    );
  }
  return value;
}

/// Indexes adapters by [EntityAdapter.entityType]; duplicate keys throw.
Map<String, EntityAdapter<dynamic>> _indexAdapters(
  List<EntityAdapter<dynamic>> adapters,
) {
  final map = <String, EntityAdapter<dynamic>>{};
  for (final adapter in adapters) {
    if (map.containsKey(adapter.entityType)) {
      throw ArgumentError(
        'Duplicate adapter for entityType: ${adapter.entityType}',
      );
    }
    map[adapter.entityType] = adapter;
  }
  return map;
}

/// Device Unix milliseconds. Production default for [UlsyncClient.open]
/// `nowMs`. Tests inject a closure; applications omit the argument.
int _systemNowMs() => DateTime.now().millisecondsSinceEpoch;

/// Sync engine: dirty queue, last-write-wins apply, live feed, one mutex.
///
/// Applications import [UlsyncClient] from `package:ulsync/ulsync.dart`.
/// Envelopes never leave this library as [SyncEvent] payloads.
/// @docImport '../transport/exceptions.dart';
library;

import 'dart:async';
import 'dart:typed_data';

import '../protocol/envelope.dart';
import '../protocol/errors.dart';
import '../protocol/origin.dart';
import '../store/entity_state.dart';
import '../store/sembast_metadata_store.dart';
import '../transport/http_sync_transport.dart';
import '../transport/sync_transport.dart';
import 'entity_adapter.dart';
import 'lww.dart';
import 'self_check_report.dart';
import 'sync_event.dart';
import 'sync_report.dart';

/// Default wire `part` for a complete snapshot of a record.
///
/// SPEC section 1.1: identity is `(id, part)`. `full` is the complete
/// snapshot. Any other non-empty string is an application-defined slice.
/// The library keeps no registry of names and does not treat `done` or
/// `deleted` as reserved. This is the default for [UlsyncClient.write]
/// and [UlsyncClient.markChanged], not the only legal value.
const String kEnvelopePart = 'full';

/// Wire `payload_encoding`. Always `json` in round 1, even when the bytes
/// are not UTF-8: the server copies the string and does not interpret it.
const String kPayloadEncoding = 'json';

/// Wire `flags`. This version always sends `0`.
///
/// Hiding a record is an application part, not a bit in this field.
/// There is no tombstone type.
const int kFlags = 0;

/// Maximum dirty rows posted in one [UlsyncClient.syncOnce] drain.
///
/// Matches the SPEC maximum for push, pull `limit`, and diff (500), so a
/// hundred-row related edit leaves in one POST. The previous value 50 was
/// the round-1 drain size while the loop still posted one envelope per
/// request. A lower drain now would split a hundred-row [UlsyncClient.writeAll]
/// across two [UlsyncClient.syncOnce] passes.
const int kPushBatchLimit = 500;

/// Page size for [SyncTransport.pull]. A full page triggers another request.
const int kPullPageLimit = 100;

/// Maximum keys in one `POST /v1/sync/diff` (SPEC section 3.4).
///
/// Matches the maximum `limit` on pull so the client has one batch size
/// for the whole protocol.
const int kDiffBatchLimit = 500;

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
  /// Identity is `(id, part)`. A blank value after trim is [ArgumentError]
  /// at [UlsyncClient.writeAll], not at construction.
  final String part;

  /// Application write for this item.
  ///
  /// Runs after the dirty mark, under the serial lock. Must not call
  /// [UlsyncClient] methods.
  final Future<void> Function() persist;
}

/// End-to-end last-write-wins client: queue, pull, live, one lock.
///
/// The application records local edits with [write] (mark first, persist
/// second, same lock) or [writeAll] for one related action that touches
/// many rows. [markChanged] remains as a low-level primitive. [syncOnce]
/// and [live] move data. The first network action of each instance is
/// SPEC section 3.5 hello, then the first [syncOnce] runs [selfCheck].
/// Protocol, HTTP, cursor, and the send queue stay inside.
final class UlsyncClient {
  /// Creates a client bound to one user, one device, one origin, and one
  /// metadata store.
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
  /// they remain required so production and tests share one constructor
  /// shape. The client still closes [transport] in [close], including a
  /// caller-supplied instance — passing a transport passes close ownership.
  ///
  /// [beforePersistIncoming] is test-only. It runs after
  /// [EntityAdapter.apply] and before metadata persist, which is the crash
  /// window between the two databases. There is no store interface (triad
  /// plan §13.9); this hook is the seam instead of `@visibleForTesting`,
  /// which would import Flutter into `lib/` and fail the import guard.
  UlsyncClient({
    required this.baseUrl,
    required String origin,
    required String userScope,
    required String sourceId,
    required this.tokenProvider,
    required this.store,
    required List<EntityAdapter<dynamic>> adapters,
    SyncTransport? transport,
    this.beforePersistIncoming,
  }) : origin = requireUlsyncOrigin(origin),
       userScope = _requireNonEmpty(userScope, 'userScope'),
       sourceId = _requireNonEmpty(sourceId, 'sourceId'),
       _adapters = _indexAdapters(adapters),
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
  final SembastMetadataStore store;

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

  /// Applied `server_seq`. Read by [SyncTransport.live]'s `appliedSince`
  /// synchronously — that callback must never call [store.readCursor].
  int _appliedCursor = 0;

  /// Whether [_appliedCursor] has been loaded from [store] this session.
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

  /// Outward events. Broadcast so a late subscriber does not throw; events
  /// with no listener are dropped (subscribe before [syncOnce] if you need
  /// pull-time events).
  final StreamController<SyncEvent> _events =
      StreamController<SyncEvent>.broadcast();

  /// Mutex tail. Each [_serialized] call waits for this, then replaces it.
  ///
  /// Covers [markChanged], the whole of [write] and [writeAll] including
  /// every persist callback, the whole of [syncOnce], and **one** live
  /// message — not the live subscription itself. Holding the lock for the
  /// lifetime of [live] would make [syncOnce] wait forever. Releasing it
  /// between the dirty mark of [write] and persist would let [syncOnce]
  /// clear the mark after `load` returned `null`. Releasing it between
  /// items of [writeAll] would let the live feed POST the first rows of a
  /// related edit.
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
  /// A blank value after trim is [ArgumentError]. This method does not
  /// require [EntityAdapter.encodePart]: it is the primitive that can
  /// mark a slice the next push will refuse to encode. Prefer [write],
  /// which throws [StateError] before marking when the encoder is missing.
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
  }) {
    _ensureOpen();
    final trimmedPart = _requireNonEmpty(part, 'part');
    return _serialized(() async {
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
  }

  /// Marks [id] dirty, then runs [persist] while holding the serial lock.
  ///
  /// This is the recommended way to record a local edit. The dirty mark is
  /// written **before** [persist] runs. The two stores (library metadata and
  /// the application's database) cannot share a transaction, so a crash in
  /// the middle must choose a side: a mark without data is healed on the
  /// next push (`load` or [EntityAdapter.encodePart] returns `null` and the
  /// engine clears dirty). Data without a mark is a silent permanent loss.
  /// That is why the order is not reversed even when "write the row first"
  /// looks more natural.
  ///
  /// [part] names the envelope cell. Default [kEnvelopePart] (`full`).
  /// Identity is `(id, part)`: a checkbox and a hide flag on the same
  /// record are two rows, and last-write-wins does not cross between
  /// them. A blank value after trim is [ArgumentError]. When [part] is not
  /// `full` and the adapter has no [EntityAdapter.encodePart], this throws
  /// [StateError] **before** the mark so [persist] does not run and an
  /// unsendable row is not left behind.
  ///
  /// The same serial lock covers [persist]. Releasing it between the mark
  /// and the application write would let a concurrent [syncOnce] observe
  /// dirty, load `null`, and clear the mark — the loss this method exists
  /// to prevent.
  ///
  /// Do not call [UlsyncClient] methods from [persist]. That would wait on
  /// this lock forever. The engine throws a [StateError] instead of hanging.
  /// Write only application data there.
  ///
  /// Returns whatever [persist] returns. If [persist] throws, the error is
  /// rethrown as-is and the dirty mark remains.
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
  }) {
    _ensureOpen();
    final trimmedPart = _requireNonEmpty(part, 'part');
    return _serialized(() async {
      _ensureOpen();
      return _writeOneLocked(
        entityType: entityType,
        id: id,
        part: trimmedPart,
        persist: persist,
      );
    });
  }

  /// Applies several [write] operations under the same lock as a single [write].
  ///
  /// Use this for one user action that touches many rows ("move done to trash").
  /// Live sync and [syncOnce] wait until every persist finished, so the feed
  /// cannot POST the first five while the rest are still being marked.
  ///
  /// An empty list is a no-op, not an error. If persist of item 5 throws, items
  /// 1–5 are marked dirty and 6…N have not started — the same contract as a
  /// throwing single [write]. This method does not open a database transaction
  /// across the application store and the metadata store: those are two files.
  ///
  /// Each item is checked, marked, and persisted in list order, with the same
  /// adapter and [EntityAdapter.encodePart] rules as [write]. Do not call
  /// [UlsyncClient] methods from [WriteOp.persist].
  ///
  /// Throws [ArgumentError] when an item names an unknown [WriteOp.entityType]
  /// or a blank [WriteOp.part]. Throws [StateError] after [close], when called
  /// from inside a persist callback, or when a named part has no encoder.
  Future<void> writeAll(List<WriteOp> ops) {
    if (ops.isEmpty) {
      return Future<void>.value();
    }
    _ensureOpen();
    return _serialized(() async {
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
  /// both key this row, not a neighbour with the same [id].
  Future<void> _markChangedLocked({
    required String entityType,
    required String id,
    required EntityAdapter<dynamic> adapter,
    required String part,
  }) async {
    final existing = await store.stateOf(
      userScope: userScope,
      entityType: entityType,
      id: id,
      part: part,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.put(
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
  /// When an adapter has no [EntityAdapter.listIds], the local phase reports
  /// unavailable instead of failing. When [includeServer] is `false`, or the
  /// transport does not implement [SyncDiffTransport], or the server answers
  /// 404/405, the server phase reports unavailable. An old server is a
  /// supported configuration.
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
  /// On the first successful call of this instance, names [origin] to the
  /// server ([_ensureOrigin]) and then runs [selfCheck] (identity, local
  /// ids, server diff). Hello is first because self-check would otherwise
  /// seed a foreign store. The existing push/pull body is unchanged: it is
  /// the drain for marks the check just made. Neither hello nor [selfCheck]
  /// is invoked from inside [_serialized] — the lock is not re-entrant,
  /// and that call would hang forever.
  ///
  /// Before pull, the engine **auto-heals** when the stored cursor is ahead
  /// of the server feed head (see README, *Local metadata*). Push and pull run
  /// under the same lock so they cannot race the live ingest. A network or
  /// HTTP `5xx` error is thrown; `dirty` stays set and the application calls
  /// this again. There is no retry timer inside the library.
  ///
  /// `applied: false` still clears dirty: the server already holds a
  /// non-inferior row (SPEC section 7). Leaving dirty set retries forever.
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
        .then((_) {
          _ensureOpen();
          return _serialized(() async {
            _ensureOpen();
            final counters = _SyncCounters();
            await _pushDirty(counters);
            await _ensureCursorLoaded();
            await _reconcileCursorIfAhead();
            await _pullPages(counters);
            return SyncReport(
              pushed: counters.pushed,
              accepted: counters.accepted,
              pulled: counters.pulled,
              applied: counters.applied,
              cursor: _appliedCursor,
            );
          });
        })
        .then((report) {
          if (!_selfCheckRunning) {
            _selfCheckDone = true;
          }
          return report;
        });
  }

  /// Returns the outbound event stream, starting the live feed once.
  ///
  /// Synchronous: hello and HTTP start on a later microtask after
  /// [_ensureOrigin], the applied cursor is loaded, and **auto-healed**
  /// when ahead of the server feed head, so a foreign store is refused
  /// before envelopes arrive and the first open does not send a stale
  /// `since`. Reopens call `appliedSince` again and see the cursor as of
  /// **now**, not as of the first [live] call.
  Stream<SyncEvent> live() {
    _ensureOpen();
    if (!_liveStarted) {
      _liveStarted = true;
      _liveDone = _runLive();
    }
    return _events.stream;
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
    await store.close();
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
  Future<void> _runOriginHandshake() async {
    final candidate = _transport;
    if (candidate is SyncHelloTransport) {
      // Separate interface; the `is` check does not promote a SyncTransport.
      final helloTransport = candidate as SyncHelloTransport;
      await helloTransport.hello(origin);
    }
    _originChecked = true;
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
    final stored = await store.readSourceId(userScope);
    if (stored == null) {
      await store.writeSourceId(userScope, sourceId);
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

  /// Phase 2: application ids vs metadata. Time `0` means unknown age.
  Future<({bool available, int marked})> _reconcileLocalIds() async {
    var anyListIds = false;
    var marked = 0;
    for (final adapter in _adapters.values) {
      final listIds = adapter.listIds;
      if (listIds == null) {
        continue;
      }
      anyListIds = true;
      final ids = await listIds();
      for (final id in ids) {
        final existing = await store.stateOf(
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
        await store.put(
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
    return (available: anyListIds, marked: marked);
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
      final states = await store.allStates(userScope);
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
    for (
      var offset = 0;
      offset < collected.probes.length;
      offset += kDiffBatchLimit
    ) {
      final end = offset + kDiffBatchLimit;
      final chunk = collected.probes.sublist(
        offset,
        end > collected.probes.length ? collected.probes.length : end,
      );
      final batch = await diffTransport.diff(chunk);
      if (batch == null) {
        if (offset == 0) {
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
        final ok = await store.markDirty(
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
    final states = await store.allStates(userScope);
    var n = 0;
    for (final row in states) {
      if (row.dirty) {
        n++;
      }
    }
    return n;
  }

  /// Loads [_appliedCursor] from [store] once per client lifetime.
  Future<void> _ensureCursorLoaded() async {
    if (_cursorLoaded) {
      return;
    }
    _appliedCursor = await store.readCursor(userScope);
    _cursorLoaded = true;
  }

  /// Server feed head from paginated `pull(since: 0)`; `0` when the feed is empty.
  Future<int> _probeFeedHead() async {
    var since = 0;
    while (true) {
      _ensureOpen();
      final page = await _transport.pull(since: since, limit: kPullPageLimit);
      if (page.envelopes.length < kPullPageLimit) {
        return page.nextCursor;
      }
      if (page.nextCursor <= since) {
        return page.nextCursor;
      }
      since = page.nextCursor;
    }
  }

  /// Resets local cursor when metadata is ahead of the server feed.
  ///
  /// After a server-side store reset, clients can keep a high sembast cursor
  /// and skip live catch-up. The server is read-only here: replay from
  /// `since=0` and idempotent [EntityAdapter.apply] realign the client.
  Future<void> _reconcileCursorIfAhead() async {
    final local = _appliedCursor;
    if (local == 0) {
      return;
    }
    final head = await _probeFeedHead();
    if (local <= head) {
      return;
    }
    await store.resetCursor(userScope);
    _appliedCursor = 0;
  }

  /// Sends up to [kPushBatchLimit] dirty rows in one [SyncTransport.push].
  ///
  /// Dirty marks of posted rows are not cleared before that call returns.
  /// A thrown transport error (including HTTP 413) leaves every posted row
  /// dirty so the next [syncOnce] retries the same related edit. Clearing a
  /// prefix on the way in would drop half a [writeAll] after a dropped
  /// connection — the hole this method exists to close.
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
  /// dirty (SPEC section 7).
  ///
  /// HTTP 413 is [UlsyncRequestRejected] like any other 4xx. There is no
  /// second send path that posts the same rows one envelope at a time: a
  /// new client against a server whose limit is still 1 is a named
  /// incompatibility, and two send paths would drift.
  Future<void> _pushDirty(_SyncCounters counters) async {
    final batch = await store.dirtyBatch(
      userScope: userScope,
      limit: kPushBatchLimit,
    );
    if (batch.isEmpty) {
      return;
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
    if (envelopes.isEmpty) {
      return;
    }
    final results = await _transport.push(envelopes);
    _requirePushResultsMatch(envelopes, results);
    for (var i = 0; i < postedRows.length; i++) {
      await _clearDirty(postedRows[i]);
      counters.pushed++;
      if (results[i].applied) {
        counters.accepted++;
      }
    }
  }

  /// Resolves payload bytes for a dirty [row], or `null` when there is
  /// nothing to send.
  ///
  /// [kEnvelopePart] uses [EntityAdapter.load] then [EntityAdapter.encode].
  /// Any other part uses [EntityAdapter.encodePart]. Returning `null` is
  /// the same contract as `load` returning `null`: the caller clears dirty
  /// without POST.
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
  Future<void> _pullPages(_SyncCounters counters) async {
    while (true) {
      _ensureOpen();
      final sinceUsed = _appliedCursor;
      final page = await _transport.pull(
        since: sinceUsed,
        limit: kPullPageLimit,
      );
      for (final envelope in page.envelopes) {
        counters.pulled++;
        await _ingest(envelope, countInReport: true, counters: counters);
      }
      await _advanceCursor(page.nextCursor);
      if (page.envelopes.length < kPullPageLimit) {
        break;
      }
      if (page.nextCursor <= sinceUsed) {
        break;
      }
    }
  }

  /// Applies one incoming envelope or skips it; always eligible to move cursor.
  ///
  /// Last-write-wins compares **only** inside `(id, part)`. A newer `done`
  /// does not beat a local `deleted`, and a newer `full` does not restore
  /// a hidden row — those are different cells. Skips and unknown types must
  /// **not** call [SembastMetadataStore.applyIncoming]: that method always
  /// writes [EntityState] and would overwrite a newer local row with an
  /// older envelope.
  ///
  /// `full` uses [EntityAdapter.decode] then [EntityAdapter.apply]. Any
  /// other part uses [EntityAdapter.applyPart]. When [applyPart] is
  /// omitted, the domain is not touched, the cursor still moves, and the
  /// part's metadata is stored so the feed is not replayed forever.
  /// Exchange does not fail: an older build must ignore a slice it does
  /// not understand.
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
    final local = await store.stateOf(
      userScope: userScope,
      entityType: envelope.entityType,
      id: envelope.id,
      part: envelope.part,
    );
    if (local != null &&
        !incomingWins(
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
    final now = DateTime.now().millisecondsSinceEpoch;
    final previousCursor = _appliedCursor;
    await store.applyIncoming(
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
  /// advances the cursor. Never compares one part against another.
  Future<bool> _applyIncomingDomain(
    EntityAdapter<dynamic> adapter,
    Envelope envelope,
  ) async {
    if (envelope.part == kEnvelopePart) {
      final value = adapter.decode(envelope.payload, envelope.schemaVersion);
      await adapter.applyValue(value);
      return true;
    }
    final applyPart = adapter.applyPart;
    if (applyPart == null) {
      return false;
    }
    await applyPart(envelope.id, envelope.part, envelope.payload);
    return true;
  }

  /// Moves the persisted cursor forward when [serverSeq] is strictly greater.
  ///
  /// Memory [_appliedCursor] updates only after a successful write. A live
  /// `cursor` event behind the applied value is a no-op (no [SyncCursorAdvanced]).
  Future<void> _advanceCursor(int serverSeq) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final moved = await store.writeCursor(userScope, serverSeq, now);
    if (!moved) {
      return;
    }
    if (serverSeq > _appliedCursor) {
      _appliedCursor = serverSeq;
    }
    _emit(SyncCursorAdvanced(_appliedCursor));
  }

  /// Clears dirty only if [row.revision] is still the stored revision.
  Future<void> _clearDirty(EntityState row) {
    return store.clearDirty(
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
        _events.addError(e, st);
      }
    }
  }

  /// Applies one live item through the same path as pull.
  Future<void> _handleLiveMessage(LiveMessage message) async {
    _ensureOpen();
    await _ensureCursorLoaded();
    switch (message) {
      case LiveEnvelope(:final envelope):
        await _ingest(envelope, countInReport: false);
      case LiveCursor(:final nextCursor):
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
    }
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

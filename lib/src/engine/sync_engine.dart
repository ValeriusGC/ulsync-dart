/// Sync engine: dirty queue, last-write-wins apply, live feed, one mutex.
///
/// Applications import [UlsyncClient] from `package:ulsync/ulsync.dart`.
/// Envelopes never leave this library as [SyncEvent] payloads.
library;

import 'dart:async';

import '../protocol/envelope.dart';
import '../protocol/errors.dart';
import '../store/entity_state.dart';
import '../store/sembast_metadata_store.dart';
import '../transport/http_sync_transport.dart';
import '../transport/sync_transport.dart';
import 'entity_adapter.dart';
import 'lww.dart';
import 'sync_event.dart';
import 'sync_report.dart';

/// Wire `part` for every envelope in round 1.
///
/// SPEC section 1.1 and triad plan §13.10 allow only `full`.
const String kEnvelopePart = 'full';

/// Wire `payload_encoding`. Always `json` in round 1, even when the bytes
/// are not UTF-8: the server copies the string and does not interpret it.
const String kPayloadEncoding = 'json';

/// Wire `flags`. Round 1 sends `0`; deletion bits are a later round.
const int kFlags = 0;

/// Maximum dirty rows drained per [UlsyncClient.syncOnce].
///
/// Round 2 changes the **body** of the push loop (one POST with a batch),
/// not the queue shape. That is the promise in triad plan section 9.
const int kPushBatchLimit = 50;

/// Page size for [SyncTransport.pull]. A full page triggers another request.
const int kPullPageLimit = 100;

/// Mutable counters for one [UlsyncClient.syncOnce] pass.
final class _SyncCounters {
  /// Envelopes actually POSTed.
  int pushed = 0;

  /// Push rows with `applied: true`.
  int accepted = 0;

  /// Pull envelopes seen this pass, including skips.
  int pulled = 0;

  /// [EntityAdapter.apply] calls this pass (not live).
  int applied = 0;
}

/// Zone key set while [UlsyncClient.write]'s persist callback runs.
///
/// Nested [UlsyncClient] calls would wait forever on the serial lock; the
/// lock helper throws [StateError] instead of hanging.
final Object _writeZoneKey = Object();

/// End-to-end last-write-wins client: queue, pull, live, one lock.
///
/// The application records local edits with [write] (mark first, persist
/// second, same lock). [markChanged] remains as a low-level primitive.
/// [syncOnce] and [live] move data. Protocol, HTTP, cursor, and the send
/// queue stay inside.
final class UlsyncClient {
  /// Creates a client bound to one user, one device, and one metadata store.
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
    required String userScope,
    required String sourceId,
    required this.tokenProvider,
    required this.store,
    required List<EntityAdapter<dynamic>> adapters,
    SyncTransport? transport,
    this.beforePersistIncoming,
  }) : userScope = _requireNonEmpty(userScope, 'userScope'),
       sourceId = _requireNonEmpty(sourceId, 'sourceId'),
       _adapters = _indexAdapters(adapters),
       _transport =
           transport ??
           HttpSyncTransport(baseUrl: baseUrl, tokenProvider: tokenProvider);

  /// Origin of the sync server. Ignored when a [SyncTransport] is injected.
  final Uri baseUrl;

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
  /// Covers [markChanged], the whole of [write] including its persist
  /// callback, the whole of [syncOnce], and **one** live message — not the
  /// live subscription itself. Holding the lock for the lifetime of [live]
  /// would make [syncOnce] wait forever. Releasing it between the dirty mark
  /// of [write] and persist would let [syncOnce] clear the mark after
  /// `load` returned `null`.
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
  /// The engine owns the revision. The application must not mint it: a stale
  /// number loses a last-write-wins tie and the edit disappears silently.
  /// Throws [ArgumentError] when no adapter is registered for [entityType]
  /// (the store is not touched). Throws [StateError] after [close], or when
  /// called from inside the persist callback of [write].
  Future<void> markChanged({required String entityType, required String id}) {
    _ensureOpen();
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
      );
    });
  }

  /// Marks [id] dirty, then runs [persist] while holding the serial lock.
  ///
  /// This is the recommended way to record a local edit. The dirty mark is
  /// written **before** [persist] runs. The two stores (library metadata and
  /// the application's database) cannot share a transaction, so a crash in
  /// the middle must choose a side: a mark without data is healed on the
  /// next push (`load` returns `null` and the engine clears dirty). Data
  /// without a mark is a silent permanent loss. That is why the order is
  /// not reversed even when "write the row first" looks more natural.
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
  /// after [close], or when called from inside another [write]'s persist
  /// callback.
  Future<T> write<T>({
    required String entityType,
    required String id,
    required Future<T> Function() persist,
  }) {
    _ensureOpen();
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
      );
      // The mark is written before entering the persist zone so this
      // method's own [_serialized] call is not treated as re-entry.
      return await runZoned(persist, zoneValues: {_writeZoneKey: true});
    });
  }

  /// Writes a dirty metadata row for [id]. Caller already holds [_serialized].
  ///
  /// Shared by [markChanged] and [write] so the two public marks cannot
  /// drift. [adapter] is already resolved; this method does not look it up.
  Future<void> _markChangedLocked({
    required String entityType,
    required String id,
    required EntityAdapter<dynamic> adapter,
  }) async {
    final existing = await store.stateOf(
      userScope: userScope,
      entityType: entityType,
      id: id,
      part: kEnvelopePart,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.put(
      EntityState(
        userScope: userScope,
        entityType: entityType,
        id: id,
        part: kEnvelopePart,
        createdAtMs: existing?.createdAtMs ?? now,
        lastEditedAtMs: now,
        revision: (existing?.revision ?? 0) + 1,
        sourceId: sourceId,
        schemaVersion: adapter.schemaVersion,
        dirty: true,
      ),
    );
  }

  /// Pushes the dirty queue, then pulls until a short page.
  ///
  /// Before pull, the engine **auto-heals** when the stored cursor is ahead
  /// of the server feed head (see README, *Local metadata*). Push and pull run
  /// under the same lock so they cannot race the live ingest. A network or
  /// HTTP `5xx` error is thrown; `dirty` stays set and the application calls
  /// this again. There is no retry timer inside the library.
  ///
  /// `applied: false` still clears dirty: the server already holds a
  /// non-inferior row (SPEC section 7). Leaving dirty set retries forever.
  Future<SyncReport> syncOnce() {
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
  }

  /// Returns the outbound event stream, starting the live feed once.
  ///
  /// Synchronous: the HTTP session starts on a later microtask after the
  /// applied cursor is loaded and **auto-healed** when ahead of the server
  /// feed head, so the first open does not send a stale `since`. Reopens call
  /// `appliedSince` again and see the cursor as of **now**, not as of the
  /// first [live] call.
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
  /// A second call is a no-op. Later [write], [markChanged], [syncOnce], or
  /// [live] throw [StateError] with `UlsyncClient is closed`. Transport is
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

  /// Runs [action] after the previous serialized job, even if that job failed.
  ///
  /// [_tail] is a [Completer] completed in `whenComplete`, not the action's
  /// own future, so one error does not stall the queue.
  ///
  /// The first line rejects re-entry from [write]'s persist callback. Nested
  /// [UlsyncClient] calls would wait on this lock forever; a [StateError] is
  /// louder than a hang in a sync library.
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

  /// Sends up to [kPushBatchLimit] dirty rows, one envelope per POST.
  Future<void> _pushDirty(_SyncCounters counters) async {
    final batch = await store.dirtyBatch(
      userScope: userScope,
      limit: kPushBatchLimit,
    );
    for (final row in batch) {
      _ensureOpen();
      final adapter = _adapters[row.entityType];
      if (adapter == null) {
        await _clearDirty(row);
        continue;
      }
      final value = await adapter.load(row.id);
      if (value == null) {
        await _clearDirty(row);
        continue;
      }
      final envelope = Envelope(
        id: row.id,
        part: row.part,
        entityType: row.entityType,
        createdAtMs: row.createdAtMs,
        lastEditedAtMs: row.lastEditedAtMs,
        revision: row.revision,
        sourceId: row.sourceId,
        flags: kFlags,
        schemaVersion: row.schemaVersion,
        payloadEncoding: kPayloadEncoding,
        payload: adapter.encodeValue(value),
      );
      // Round 2 will POST a batch; the queue is already a list. One envelope
      // per request is the round-1 server limit (max_envelopes_per_push: 1).
      final results = await _transport.push([envelope]);
      final result = _pushResultFor(results, envelope.id);
      await _clearDirty(row);
      counters.pushed++;
      if (result.applied) {
        counters.accepted++;
      }
    }
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
  /// Last-write-wins skips and unknown types must **not** call
  /// [SembastMetadataStore.applyIncoming]: that method always writes
  /// [EntityState] and would overwrite a newer local row with an older
  /// envelope.
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
    final value = adapter.decode(envelope.payload, envelope.schemaVersion);
    await adapter.applyValue(value);
    if (countInReport) {
      counters?.applied++;
    }
    await beforePersistIncoming?.call();
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
    _emit(
      SyncApplied([
        SyncedEntity(entityType: envelope.entityType, id: envelope.id),
      ]),
    );
    if (_appliedCursor > previousCursor) {
      _emit(SyncCursorAdvanced(_appliedCursor));
    }
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

  /// Picks the push row for [id], or the sole row when the list has one.
  PushResult _pushResultFor(List<PushResult> results, String id) {
    for (final row in results) {
      if (row.id == id) {
        return row;
      }
    }
    if (results.length == 1) {
      return results.single;
    }
    throw UlsyncProtocolException(
      'Push response missing result for $id',
      field: 'results',
    );
  }

  /// Opens the transport live feed and ingests each message under the lock.
  Future<void> _runLive() async {
    try {
      await _serialized(() async {
        await _ensureCursorLoaded();
        await _reconcileCursorIfAhead();
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

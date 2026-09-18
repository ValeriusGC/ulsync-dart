/// Per-user metadata persistence on sembast.
///
/// Stores entity sync state (one row per `(id, part)` cell of a record kit)
/// and server feed cursors in a database file separate from the
/// application's own storage. The engine packs those cells into
/// **indivisible, complete** kits at push time.
library;

import 'package:sembast/sembast.dart';

import 'entity_state.dart';
import 'platform/default_factory.dart';

/// Layout version of the metadata database.
///
/// Bumped only together with a migration in [_onVersionChanged]. The store
/// refuses to open anything it was not written for: silently working on an
/// unknown layout is how user data disappears.
const int _databaseVersion = 1;

/// Entity metadata records keyed by user, type, id, and part.
final _entities = stringMapStoreFactory.store('ulsync_entity');

/// Per-user server feed cursor records keyed by [EntityState.userScope].
final _cursors = stringMapStoreFactory.store('ulsync_cursor');

/// Installation identity (`source_id`) last stored for a [EntityState.userScope].
///
/// A new named store does not bump [_databaseVersion]: sembast materializes
/// it on first write. Existing version-1 files keep opening.
final _sourceIds = stringMapStoreFactory.store('ulsync_source_id');

/// Per-user store-clock offset last sampled for a [EntityState.userScope].
///
/// A new named store does not bump [_databaseVersion]: there is no
/// migration, and bumping the layout version would refuse every existing
/// metadata file. Sembast materializes this store on first write, the
/// same way as [_sourceIds].
final _clockOffsets = stringMapStoreFactory.store('ulsync_clock_offset');

/// Key of one entity record.
///
/// Every part is percent-escaped before joining: without it the pairs
/// ("a|b", "t") and ("a", "b|t") collapse into the same key, which silently
/// mixes two users' data.
String _entityKey({
  required String userScope,
  required String entityType,
  required String id,
  required String part,
}) => [userScope, entityType, id, part].map(Uri.encodeComponent).join('|');

/// Storage key derived from [state]'s identifying fields.
String _entityKeyOf(EntityState state) => _entityKey(
  userScope: state.userScope,
  entityType: state.entityType,
  id: state.id,
  part: state.part,
);

/// Serializes [state] for sembast; field names match the in-record indexes.
Map<String, Object?> _toMap(EntityState state) => {
  'userScope': state.userScope,
  'entityType': state.entityType,
  'id': state.id,
  'part': state.part,
  'createdAtMs': state.createdAtMs,
  'lastEditedAtMs': state.lastEditedAtMs,
  'revision': state.revision,
  'sourceId': state.sourceId,
  'schemaVersion': state.schemaVersion,
  'dirty': state.dirty,
};

/// Rebuilds [EntityState] from a stored map; corrupt records fail here.
EntityState _fromMap(Map<String, Object?> map) => EntityState(
  userScope: map['userScope']! as String,
  entityType: map['entityType']! as String,
  id: map['id']! as String,
  part: map['part']! as String,
  createdAtMs: map['createdAtMs']! as int,
  lastEditedAtMs: map['lastEditedAtMs']! as int,
  revision: map['revision']! as int,
  sourceId: map['sourceId']! as String,
  schemaVersion: map['schemaVersion']! as int,
  dirty: map['dirty']! as bool,
);

/// Called when the on-disk layout version does not match [_databaseVersion].
Future<void> _onVersionChanged(
  Database db,
  int oldVersion,
  int newVersion,
) async {
  // Fresh database: sembast materializes a store on first write, so there is
  // nothing to create here.
  if (oldVersion == 0) {
    return;
  }
  throw StateError(
    'ulsync metadata database is version $oldVersion, this release expects '
    '$newVersion. Migration is not implemented; do not delete the file '
    'manually, report the mismatch instead.',
  );
}

/// Sembast-backed store for sync metadata: cursors, dirty flags, and entity
/// revision tracking per [EntityState.userScope].
final class SembastMetadataStore {
  SembastMetadataStore._(this._db);

  final Database _db;

  /// Whether [close] has already run.
  bool _closed = false;

  /// Opens the metadata database at [databasePath].
  ///
  /// On mobile and desktop [databasePath] is a file path; in the browser it is
  /// a store name. When [factory] is omitted, the library picks the platform
  /// default via a conditional export. Pass [factory] only in application tests
  /// (for example [databaseFactoryMemory]).
  static Future<SembastMetadataStore> open({
    required String databasePath,
    DatabaseFactory? factory,
  }) async {
    final resolvedFactory = factory ?? defaultDatabaseFactory;
    final db = await resolvedFactory.openDatabase(
      databasePath,
      version: _databaseVersion,
      onVersionChanged: _onVersionChanged,
    );
    return SembastMetadataStore._(db);
  }

  /// Closes the database. Repeated calls are ignored.
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _db.close();
  }

  /// Returns stored metadata for one entity part, or `null` when unknown.
  Future<EntityState?> stateOf({
    required String userScope,
    required String entityType,
    required String id,
    required String part,
  }) async {
    final stored = await _entities
        .record(
          _entityKey(
            userScope: userScope,
            entityType: entityType,
            id: id,
            part: part,
          ),
        )
        .get(_db);
    if (stored == null) {
      return null;
    }
    return _fromMap(stored);
  }

  /// Inserts or replaces metadata for [state].
  Future<void> put(EntityState state) =>
      _entities.record(_entityKeyOf(state)).put(_db, _toMap(state));

  /// Every dirty row for [userScope], oldest edit first.
  ///
  /// The engine packs **indivisible, complete** record kits from this list
  /// so a push never splits `full` / `done` / `deleted` of one id. This
  /// method does not apply the SPEC ceiling.
  Future<List<EntityState>> allDirty(String userScope) async {
    final found = await _entities.find(
      _db,
      finder: Finder(
        filter: Filter.and([
          Filter.equals('userScope', userScope),
          Filter.equals('dirty', true),
        ]),
        sortOrders: [SortOrder('lastEditedAtMs'), SortOrder('id')],
      ),
    );
    return found.map((s) => _fromMap(s.value)).toList(growable: false);
  }

  /// Pending entities for [userScope], oldest edit first, at most [limit] rows.
  ///
  /// This is a raw window. Push packing uses [allDirty] plus complete-kit
  /// assembly so a limit of 500 cannot cut an **indivisible** record kit
  /// in half.
  Future<List<EntityState>> dirtyBatch({
    required String userScope,
    required int limit,
  }) async {
    final found = await _entities.find(
      _db,
      finder: Finder(
        filter: Filter.and([
          Filter.equals('userScope', userScope),
          Filter.equals('dirty', true),
        ]),
        // Second key makes the order total: equal timestamps otherwise produce
        // a different batch on every run and a flaky test with it.
        sortOrders: [SortOrder('lastEditedAtMs'), SortOrder('id')],
        limit: limit,
      ),
    );
    return found.map((s) => _fromMap(s.value)).toList(growable: false);
  }

  /// Clears [dirty] only when the stored revision still equals
  /// [expectedRevision] and the row is still dirty.
  ///
  /// Returns `true` when the flag was cleared, `false` when the record is
  /// missing, already clean, or was edited again after the push started.
  /// HTTP push holds no engine lock, so a later persist of the same cell
  /// must not be wiped by the `200` for the older snapshot.
  Future<bool> clearDirty({
    required String userScope,
    required String entityType,
    required String id,
    required String part,
    required int expectedRevision,
  }) {
    final record = _entities.record(
      _entityKey(
        userScope: userScope,
        entityType: entityType,
        id: id,
        part: part,
      ),
    );
    return _db.transaction((txn) async {
      final stored = await record.get(txn);
      if (stored == null || stored['revision'] != expectedRevision) {
        return false;
      }
      if (stored['dirty'] != true) {
        return false;
      }
      await record.update(txn, {'dirty': false});
      return true;
    });
  }

  /// Sets dirty on an existing record **without touching its clock**.
  ///
  /// This is a library primitive; application code should not call it.
  /// Returns `false` when the record is unknown to the library. Neither
  /// lastEditedAtMs, nor createdAtMs, nor revision changes: they are the ranks
  /// of conflict resolution (SPEC section 2), and a reconciliation that
  /// refreshed them would let a stale local copy defeat a newer copy from
  /// another device — the very data loss this round removes.
  Future<bool> markDirty({
    required String userScope,
    required String entityType,
    required String id,
    required String part,
  }) {
    final record = _entities.record(
      _entityKey(
        userScope: userScope,
        entityType: entityType,
        id: id,
        part: part,
      ),
    );
    return _db.transaction((txn) async {
      final stored = await record.get(txn);
      if (stored == null) {
        return false;
      }
      if (stored['dirty'] == true) {
        return true;
      }
      await record.update(txn, {'dirty': true});
      return true;
    });
  }

  /// Every known record of one user, dirty and clean alike.
  ///
  /// This is a library primitive; application code should not call it.
  /// Used by the divergence check to build its request. The whole database is
  /// in memory anyway, so this adds no I/O.
  Future<List<EntityState>> allStates(String userScope) async {
    final found = await _entities.find(
      _db,
      finder: Finder(
        filter: Filter.equals('userScope', userScope),
        sortOrders: [SortOrder('id'), SortOrder('entityType')],
      ),
    );
    return found.map((s) => _fromMap(s.value)).toList(growable: false);
  }

  /// The source_id this user scope was last opened with, or null on first open.
  ///
  /// This is a library primitive; application code should not call it.
  /// Stored so a changed installation identity is reported instead of silently
  /// producing envelopes under a new third conflict rank (SPEC sections 1.4, 2).
  Future<String?> readSourceId(String userScope) async {
    final stored = await _sourceIds.record(userScope).get(_db);
    if (stored == null) {
      return null;
    }
    return stored['sourceId']! as String;
  }

  /// Records [sourceId] for [userScope]. Called once, on the first open.
  ///
  /// This is a library primitive; application code should not call it.
  Future<void> writeSourceId(String userScope, String sourceId) {
    return _sourceIds.record(userScope).put(_db, {'sourceId': sourceId});
  }

  /// Offset and sample flag last stored for [userScope], or null before
  /// the first `server_now_ms`.
  ///
  /// This is a library primitive; application code should not call it.
  /// After [close] + [open] with the same `inMemory` name, a write before
  /// the next hello must use this offset, not raw device milliseconds.
  Future<StoredClockOffset?> readClockOffset(String userScope) async {
    final stored = await _clockOffsets.record(userScope).get(_db);
    if (stored == null) {
      return null;
    }
    return StoredClockOffset(
      offsetMs: stored['offsetMs']! as int,
      sampled: stored['sampled']! as bool,
    );
  }

  /// Persists [offsetMs] and, on the first sample only, restamps dirty
  /// rows of [sourceId].
  ///
  /// This is a library primitive; application code should not call it.
  /// The rewrite and the sample flag share one transaction so a crash
  /// cannot leave dirty stamps shifted without recording that a sample
  /// already happened (which would shift them again on the next hello).
  /// Foreign `source_id`, clean rows, and incoming ranks are not written
  /// here: last-write-wins on the wire is the envelope the neighbour sent,
  /// not this device's offset. A later sample passes [rewriteDirty] false.
  /// [_databaseVersion] stays `1`: this named store is created on first
  /// put, like `ulsync_source_id`.
  Future<void> persistClockSample({
    required String userScope,
    required String sourceId,
    required int offsetMs,
    required bool rewriteDirty,
  }) {
    return _db.transaction((txn) async {
      if (rewriteDirty) {
        final found = await _entities.find(
          txn,
          finder: Finder(
            filter: Filter.and([
              Filter.equals('userScope', userScope),
              Filter.equals('dirty', true),
            ]),
          ),
        );
        for (final snapshot in found) {
          final state = _fromMap(snapshot.value);
          if (state.sourceId != sourceId) {
            continue;
          }
          final editedBefore = state.lastEditedAtMs;
          final created = state.createdAtMs == editedBefore
              ? state.createdAtMs + offsetMs
              : state.createdAtMs;
          await _entities
              .record(_entityKeyOf(state))
              .put(
                txn,
                _toMap(
                  EntityState(
                    userScope: state.userScope,
                    entityType: state.entityType,
                    id: state.id,
                    part: state.part,
                    createdAtMs: created,
                    lastEditedAtMs: editedBefore + offsetMs,
                    revision: state.revision,
                    sourceId: state.sourceId,
                    schemaVersion: state.schemaVersion,
                    dirty: state.dirty,
                  ),
                ),
              );
        }
      }
      await _clockOffsets.record(userScope).put(txn, {
        'offsetMs': offsetMs,
        'sampled': true,
      });
    });
  }

  /// Writes [state] and advances the feed cursor in one transaction.
  ///
  /// If [serverSeq] is not greater than the stored cursor, the state is still
  /// written but the cursor is left unchanged — out-of-order pages must not
  /// move the cursor backwards.
  Future<void> applyIncoming({
    required EntityState state,
    required int serverSeq,
    required int atMs,
  }) => _db.transaction((txn) async {
    await _entities.record(_entityKeyOf(state)).put(txn, _toMap(state));
    // The return value is intentionally ignored: a page applied out of order
    // must not push the cursor back, and that is exactly what `false` means.
    await _writeCursorIn(txn, state.userScope, serverSeq, atMs);
  });

  /// Last server sequence applied for [userScope]; `0` when never synced.
  Future<int> readCursor(String userScope) async {
    final stored = await _cursors.record(userScope).get(_db);
    return stored == null ? 0 : stored['serverSeq']! as int;
  }

  /// Clears the stored feed cursor for [userScope].
  ///
  /// Used when local metadata is ahead of the server feed (for example after
  /// a server-side store reset). Entity rows are not deleted; the next pull
  /// replays from the beginning and [EntityAdapter.apply] must be idempotent.
  Future<void> resetCursor(String userScope) async {
    await _cursors.record(userScope).delete(_db);
  }

  /// Advances the cursor when [serverSeq] is greater than the stored value.
  ///
  /// Returns `false` when [serverSeq] is not greater than what is already
  /// stored; the cursor never moves backwards.
  Future<bool> writeCursor(String userScope, int serverSeq, int atMs) =>
      _db.transaction((txn) => _writeCursorIn(txn, userScope, serverSeq, atMs));

  /// Moves the cursor forward inside an existing transaction.
  ///
  /// Returns `false` when [serverSeq] is not greater than the stored value:
  /// a cursor that moves backwards re-delivers data the application already
  /// has, and the caller is not asked to remember this rule.
  Future<bool> _writeCursorIn(
    DatabaseClient client,
    String userScope,
    int serverSeq,
    int atMs,
  ) async {
    final record = _cursors.record(userScope);
    final stored = await record.get(client);
    final current = stored == null ? 0 : stored['serverSeq']! as int;
    if (serverSeq <= current) {
      return false;
    }
    await record.put(client, {'serverSeq': serverSeq, 'lastSyncAtMs': atMs});
    return true;
  }
}

/// Offset from a `server_now_ms` sample, keyed by user scope in the
/// metadata file.
///
/// Not exported from `package:ulsync/ulsync.dart`. After the first sample
/// [sampled] is true and a later `write` before the next hello uses
/// [offsetMs], not raw device milliseconds. Layout version stays `1`
/// because this value lives in a new named store, not a new layout.
final class StoredClockOffset {
  /// Creates the persisted sample for one user scope.
  const StoredClockOffset({required this.offsetMs, required this.sampled});

  /// `server_now_ms − nowMs` at the last sample. Added to outgoing stamps.
  final int offsetMs;

  /// Whether a store clock sample has already been applied.
  ///
  /// Distinguishes "offset 0 because clocks already matched" from "no
  /// sample yet, stamp raw `nowMs`". A repeat sample must not rewrite
  /// dirty rows a second time.
  final bool sampled;
}

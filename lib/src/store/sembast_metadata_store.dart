/// Per-user metadata persistence on sembast.
///
/// Stores entity sync state and server feed cursors in a database file separate
/// from the application's own storage.
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

  /// Pending entities for [userScope], oldest edit first, at most [limit] rows.
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
  /// [expectedRevision].
  ///
  /// Returns `true` when the flag was cleared, `false` when the record is
  /// missing or was edited again after the push started.
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

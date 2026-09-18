/// Tests for [SembastMetadataStore] on an in-memory sembast database.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:ulsync/src/store/entity_state.dart';
import 'package:ulsync/src/store/sembast_metadata_store.dart';

/// Monotonic suffix so parallel tests never share a database name.
var _pathCounter = 0;

/// Opens a fresh in-memory store and deletes it when the test ends.
Future<SembastMetadataStore> openMemoryStore() async {
  final factory = databaseFactoryMemory;
  final path = 'metadata_store_test_${_pathCounter++}.db';
  await factory.deleteDatabase(path);
  final store = await SembastMetadataStore.open(
    databasePath: path,
    factory: factory,
  );
  addTearDown(() async {
    await store.close();
    await factory.deleteDatabase(path);
  });
  return store;
}

/// Builds a sample [EntityState] with overridable fields.
EntityState sampleState({
  String userScope = 'alice',
  String entityType = 'note',
  String id = 'entity-1',
  String part = 'full',
  int createdAtMs = 1_000,
  int lastEditedAtMs = 2_000,
  int revision = 1,
  String sourceId = 'device-a',
  int schemaVersion = 1,
  bool dirty = false,
}) => EntityState(
  userScope: userScope,
  entityType: entityType,
  id: id,
  part: part,
  createdAtMs: createdAtMs,
  lastEditedAtMs: lastEditedAtMs,
  revision: revision,
  sourceId: sourceId,
  schemaVersion: schemaVersion,
  dirty: dirty,
);

void main() {
  test(
    'open creates a database and unknown user cursor reads as zero',
    () async {
      final store = await openMemoryStore();
      expect(await store.readCursor('nobody'), 0);
    },
  );

  test('writeCursor and readCursor round-trip', () async {
    final store = await openMemoryStore();
    expect(await store.writeCursor('alice', 42, 9_000), isTrue);
    expect(await store.readCursor('alice'), 42);
  });

  test('cursors are isolated per userScope', () async {
    final store = await openMemoryStore();
    await store.writeCursor('alice', 100, 1_000);
    expect(await store.readCursor('bob'), 0);
    final aliceState = sampleState(userScope: 'alice', id: 'shared-id');
    final bobState = sampleState(userScope: 'bob', id: 'shared-id');
    await store.put(aliceState);
    await store.put(bobState);
    expect(
      await store.stateOf(
        userScope: 'alice',
        entityType: 'note',
        id: 'shared-id',
        part: 'full',
      ),
      equals(aliceState),
    );
    expect(
      await store.stateOf(
        userScope: 'bob',
        entityType: 'note',
        id: 'shared-id',
        part: 'full',
      ),
      equals(bobState),
    );
  });

  test('pipe characters in key parts do not collide across users', () async {
    final store = await openMemoryStore();
    final left = sampleState(userScope: 'a|b', entityType: 'note', id: 'x');
    final right = sampleState(userScope: 'a', entityType: 'b|note', id: 'x');
    await store.put(left);
    await store.put(right);
    expect(
      await store.stateOf(
        userScope: 'a|b',
        entityType: 'note',
        id: 'x',
        part: 'full',
      ),
      equals(left),
    );
    expect(
      await store.stateOf(
        userScope: 'a',
        entityType: 'b|note',
        id: 'x',
        part: 'full',
      ),
      equals(right),
    );
  });

  test('put replaces an existing record with the same key', () async {
    final store = await openMemoryStore();
    final first = sampleState(revision: 1, lastEditedAtMs: 100);
    final second = sampleState(revision: 2, lastEditedAtMs: 200, dirty: true);
    await store.put(first);
    await store.put(second);
    expect(
      await store.stateOf(
        userScope: 'alice',
        entityType: 'note',
        id: 'entity-1',
        part: 'full',
      ),
      equals(second),
    );
  });

  test(
    'dirtyBatch returns only dirty rows sorted by edit time then id',
    () async {
      final store = await openMemoryStore();
      await store.put(sampleState(id: 'b', lastEditedAtMs: 300, dirty: true));
      await store.put(sampleState(id: 'a', lastEditedAtMs: 300, dirty: true));
      await store.put(sampleState(id: 'c', lastEditedAtMs: 100, dirty: true));
      await store.put(sampleState(id: 'clean', dirty: false));
      final batch = await store.dirtyBatch(userScope: 'alice', limit: 10);
      expect(batch.map((s) => s.id), ['c', 'a', 'b']);
    },
  );

  test('dirtyBatch respects the limit', () async {
    final store = await openMemoryStore();
    for (var i = 0; i < 5; i++) {
      await store.put(
        sampleState(id: 'e$i', lastEditedAtMs: i * 10, dirty: true),
      );
    }
    final batch = await store.dirtyBatch(userScope: 'alice', limit: 2);
    expect(batch, hasLength(2));
  });

  test('dirtyBatch never returns another userScope', () async {
    final store = await openMemoryStore();
    await store.put(sampleState(userScope: 'alice', id: 'a', dirty: true));
    await store.put(sampleState(userScope: 'bob', id: 'b', dirty: true));
    final batch = await store.dirtyBatch(userScope: 'alice', limit: 10);
    expect(batch, hasLength(1));
    expect(batch.single.id, 'a');
  });

  test('clearDirty clears the flag when revision matches', () async {
    final store = await openMemoryStore();
    await store.put(sampleState(revision: 3, dirty: true));
    expect(
      await store.clearDirty(
        userScope: 'alice',
        entityType: 'note',
        id: 'entity-1',
        part: 'full',
        expectedRevision: 3,
      ),
      isTrue,
    );
    final batch = await store.dirtyBatch(userScope: 'alice', limit: 10);
    expect(batch, isEmpty);
  });

  test('clearDirty leaves the row dirty when revision changed', () async {
    final store = await openMemoryStore();
    await store.put(sampleState(revision: 3, dirty: true));
    await store.put(sampleState(revision: 4, dirty: true));
    expect(
      await store.clearDirty(
        userScope: 'alice',
        entityType: 'note',
        id: 'entity-1',
        part: 'full',
        expectedRevision: 3,
      ),
      isFalse,
    );
    final batch = await store.dirtyBatch(userScope: 'alice', limit: 10);
    expect(batch, hasLength(1));
    expect(batch.single.revision, 4);
  });

  test('applyIncoming rolls back when the transaction aborts', () async {
    final factory = databaseFactoryMemory;
    final path = 'apply_abort_${_pathCounter++}.db';
    await factory.deleteDatabase(path);

    final store = await SembastMetadataStore.open(
      databasePath: path,
      factory: factory,
    );
    await store.writeCursor('alice', 10, 500);
    await store.close();

    final incoming = sampleState(revision: 2, dirty: false);
    final entities = stringMapStoreFactory.store('ulsync_entity');
    final cursors = stringMapStoreFactory.store('ulsync_cursor');
    final raw = await factory.openDatabase(path, version: 1);
    await expectLater(
      raw.transaction((txn) async {
        await entities
            .record(
              [
                incoming.userScope,
                incoming.entityType,
                incoming.id,
                incoming.part,
              ].map(Uri.encodeComponent).join('|'),
            )
            .put(txn, {
              'userScope': incoming.userScope,
              'entityType': incoming.entityType,
              'id': incoming.id,
              'part': incoming.part,
              'createdAtMs': incoming.createdAtMs,
              'lastEditedAtMs': incoming.lastEditedAtMs,
              'revision': incoming.revision,
              'sourceId': incoming.sourceId,
              'schemaVersion': incoming.schemaVersion,
              'dirty': incoming.dirty,
            });
        await cursors.record('alice').put(txn, {
          'serverSeq': 20,
          'lastSyncAtMs': 600,
        });
        throw StateError('injected failure');
      }),
      throwsA(isA<StateError>()),
    );
    await raw.close();

    final reopened = await SembastMetadataStore.open(
      databasePath: path,
      factory: factory,
    );
    addTearDown(() async {
      await reopened.close();
      await factory.deleteDatabase(path);
    });
    expect(
      await reopened.stateOf(
        userScope: 'alice',
        entityType: 'note',
        id: 'entity-1',
        part: 'full',
      ),
      isNull,
    );
    expect(await reopened.readCursor('alice'), 10);
  });

  test(
    'applyIncoming is idempotent when called twice with the same data',
    () async {
      final store = await openMemoryStore();
      final incoming = sampleState(revision: 2, dirty: false);
      await store.applyIncoming(state: incoming, serverSeq: 30, atMs: 700);
      await store.applyIncoming(state: incoming, serverSeq: 30, atMs: 700);
      expect(
        await store.stateOf(
          userScope: 'alice',
          entityType: 'note',
          id: 'entity-1',
          part: 'full',
        ),
        equals(incoming),
      );
      expect(await store.readCursor('alice'), 30);
    },
  );

  test('writeCursor refuses to move backwards or stay equal', () async {
    final store = await openMemoryStore();
    expect(await store.writeCursor('alice', 100, 1_000), isTrue);
    expect(await store.writeCursor('alice', 50, 2_000), isFalse);
    expect(await store.readCursor('alice'), 100);
    expect(await store.writeCursor('alice', 100, 3_000), isFalse);
    expect(await store.readCursor('alice'), 100);
  });

  test('refuses a database written by a newer release', () async {
    final factory = databaseFactoryMemory;
    final path = 'version_mismatch_${_pathCounter++}.db';
    await factory.deleteDatabase(path);
    final newer = await factory.openDatabase(path, version: 2);
    await newer.close();
    await expectLater(
      SembastMetadataStore.open(databasePath: path, factory: factory),
      throwsA(
        isA<StateError>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('2'), contains('1')),
        ),
      ),
    );
    await factory.deleteDatabase(path);
  });

  test('markDirty sets dirty and leaves every other field unchanged', () async {
    final store = await openMemoryStore();
    final before = sampleState(
      createdAtMs: 1_111,
      lastEditedAtMs: 2_222,
      revision: 7,
      sourceId: 'device-a',
      schemaVersion: 3,
      dirty: false,
    );
    await store.put(before);
    expect(
      await store.markDirty(
        userScope: 'alice',
        entityType: 'note',
        id: 'entity-1',
        part: 'full',
      ),
      isTrue,
    );
    final after = await store.stateOf(
      userScope: 'alice',
      entityType: 'note',
      id: 'entity-1',
      part: 'full',
    );
    expect(after, isNotNull);
    expect(after!.dirty, isTrue);
    expect(after.createdAtMs, before.createdAtMs);
    expect(after.lastEditedAtMs, before.lastEditedAtMs);
    expect(after.revision, before.revision);
    expect(after.sourceId, before.sourceId);
    expect(after.schemaVersion, before.schemaVersion);
    expect(after.userScope, before.userScope);
    expect(after.entityType, before.entityType);
    expect(after.id, before.id);
    expect(after.part, before.part);
  });

  test(
    'markDirty returns false for an unknown row and creates nothing',
    () async {
      final store = await openMemoryStore();
      expect(
        await store.markDirty(
          userScope: 'alice',
          entityType: 'note',
          id: 'no-such',
          part: 'full',
        ),
        isFalse,
      );
      expect(
        await store.stateOf(
          userScope: 'alice',
          entityType: 'note',
          id: 'no-such',
          part: 'full',
        ),
        isNull,
      );
      expect(await store.allStates('alice'), isEmpty);
    },
  );

  test('allStates returns only the requested userScope', () async {
    final store = await openMemoryStore();
    await store.put(sampleState(userScope: 'alice', id: 'a1', dirty: true));
    await store.put(sampleState(userScope: 'alice', id: 'a2', dirty: false));
    await store.put(sampleState(userScope: 'bob', id: 'b1', dirty: true));
    final alice = await store.allStates('alice');
    expect(alice.map((s) => s.id), ['a1', 'a2']);
    expect(await store.allStates('bob').then((s) => s.map((e) => e.id)), [
      'b1',
    ]);
    expect(await store.allStates('carol'), isEmpty);
  });

  test(
    'readSourceId is null until writeSourceId and does not leak across users',
    () async {
      final store = await openMemoryStore();
      expect(await store.readSourceId('alice'), isNull);
      await store.writeSourceId('alice', 'device-a');
      expect(await store.readSourceId('alice'), 'device-a');
      expect(await store.readSourceId('bob'), isNull);
      await store.writeSourceId('bob', 'device-b');
      expect(await store.readSourceId('alice'), 'device-a');
      expect(await store.readSourceId('bob'), 'device-b');
    },
  );
}

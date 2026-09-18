@TestOn('browser')
/// Exercises [SembastMetadataStore] through the browser default factory.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync/src/store/entity_state.dart';
import 'package:ulsync/src/store/sembast_metadata_store.dart';

/// Monotonic suffix so browser runs do not share IndexedDB names.
var _pathCounter = 0;

/// Opens a store using the platform default factory (no explicit [factory]).
Future<SembastMetadataStore> openBrowserStore() async {
  final path = 'ulsync_web_test_${_pathCounter++}.db';
  final store = await SembastMetadataStore.open(databasePath: path);
  addTearDown(store.close);
  return store;
}

EntityState _sample({
  String userScope = 'alice',
  String id = 'web-1',
  int revision = 1,
  bool dirty = false,
  int lastEditedAtMs = 100,
}) => EntityState(
  userScope: userScope,
  entityType: 'note',
  id: id,
  part: 'full',
  createdAtMs: 1,
  lastEditedAtMs: lastEditedAtMs,
  revision: revision,
  sourceId: 'browser',
  schemaVersion: 1,
  dirty: dirty,
);

void main() {
  test('writeCursor and readCursor round-trip in the browser', () async {
    final store = await openBrowserStore();
    expect(await store.writeCursor('alice', 12, 500), isTrue);
    expect(await store.readCursor('alice'), 12);
  });

  test('put, stateOf, dirtyBatch, and clearDirty in the browser', () async {
    final store = await openBrowserStore();
    await store.put(_sample(dirty: true, revision: 2));
    expect(
      await store.stateOf(
        userScope: 'alice',
        entityType: 'note',
        id: 'web-1',
        part: 'full',
      ),
      isNotNull,
    );
    final batch = await store.dirtyBatch(userScope: 'alice', limit: 10);
    expect(batch, hasLength(1));
    expect(
      await store.clearDirty(
        userScope: 'alice',
        entityType: 'note',
        id: 'web-1',
        part: 'full',
        expectedRevision: 2,
      ),
      isTrue,
    );
    expect(await store.dirtyBatch(userScope: 'alice', limit: 10), isEmpty);
  });

  test(
    'clearDirty returns false when revision mismatches in the browser',
    () async {
      final store = await openBrowserStore();
      await store.put(_sample(dirty: true, revision: 2));
      await store.put(_sample(dirty: true, revision: 3));
      expect(
        await store.clearDirty(
          userScope: 'alice',
          entityType: 'note',
          id: 'web-1',
          part: 'full',
          expectedRevision: 2,
        ),
        isFalse,
      );
      expect(
        await store.dirtyBatch(userScope: 'alice', limit: 10),
        hasLength(1),
      );
    },
  );

  test('applyIncoming and reopen survive in the browser', () async {
    final path = 'ulsync_web_reopen_${_pathCounter++}.db';
    final store = await SembastMetadataStore.open(databasePath: path);
    final incoming = _sample(revision: 4, dirty: false);
    await store.applyIncoming(state: incoming, serverSeq: 99, atMs: 800);
    await store.close();

    final reopened = await SembastMetadataStore.open(databasePath: path);
    addTearDown(reopened.close);
    expect(await reopened.readCursor('alice'), 99);
    expect(
      await reopened.stateOf(
        userScope: 'alice',
        entityType: 'note',
        id: 'web-1',
        part: 'full',
      ),
      equals(incoming),
    );
  });
}

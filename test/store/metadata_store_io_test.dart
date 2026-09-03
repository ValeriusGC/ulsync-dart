@TestOn('vm')
/// File-backed persistence and default platform factory checks.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync/ulsync.dart';

void main() {
  test('cursor and dirty flags survive close and reopen on a file', () async {
    final dir = Directory.systemTemp.createTempSync('ulsync_store_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/metadata.db';

    final store = await SembastMetadataStore.open(databasePath: path);
    await store.writeCursor('alice', 77, 5_000);
    await store.put(
      EntityState(
        userScope: 'alice',
        entityType: 'note',
        id: 'persisted',
        part: 'full',
        createdAtMs: 1,
        lastEditedAtMs: 2,
        revision: 1,
        sourceId: 'device',
        schemaVersion: 1,
        dirty: true,
      ),
    );
    await store.close();

    final reopened = await SembastMetadataStore.open(databasePath: path);
    addTearDown(reopened.close);
    expect(await reopened.readCursor('alice'), 77);
    final batch = await reopened.dirtyBatch(userScope: 'alice', limit: 10);
    expect(batch, hasLength(1));
    expect(batch.single.id, 'persisted');
  });

  test('open without factory uses the platform file implementation', () async {
    final dir = Directory.systemTemp.createTempSync('ulsync_default_factory_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/default_factory.db';

    final store = await SembastMetadataStore.open(databasePath: path);
    await store.writeCursor('alice', 5, 100);
    await store.close();

    expect(File(path).existsSync(), isTrue);

    final reopened = await SembastMetadataStore.open(databasePath: path);
    addTearDown(reopened.close);
    expect(await reopened.readCursor('alice'), 5);
  });
}

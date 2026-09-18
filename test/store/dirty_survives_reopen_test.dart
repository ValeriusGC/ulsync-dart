@TestOn('vm')
/// File-backed dirty flag survives [SembastMetadataStore] close and reopen.
///
/// Engine tests must not call [UlsyncClient.open] without `inMemory: true`:
/// that resolves `path_provider` and throws `MissingPluginException` on
/// the VM. This file uses the store's IO factory and a temp path.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync/src/store/entity_state.dart';
import 'package:ulsync/src/store/sembast_metadata_store.dart';

void main() {
  test('file store: dirty row survives store close and reopen', () async {
    final dir = Directory.systemTemp.createTempSync('ulsync_dirty_reopen_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/metadata.db';

    final store = await SembastMetadataStore.open(databasePath: path);
    await store.put(
      const EntityState(
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
    final row = await reopened.stateOf(
      userScope: 'alice',
      entityType: 'note',
      id: 'persisted',
      part: 'full',
    );
    expect(row, isNotNull);
    expect(row!.dirty, isTrue);
  });
}

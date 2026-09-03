@TestOn('vm')

/// Optional sizing run for the metadata database (not part of CI).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync/ulsync.dart';

/// Set with `--dart-define=ULSYNC_MEASURE=true`.
const _enabled = bool.fromEnvironment('ULSYNC_MEASURE');

void main() {
  test(
    'metadata store cost for 10000 entities',
    () async {
      final dir = Directory.systemTemp.createTempSync('ulsync_measure_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/measure.db';

      final store = await SembastMetadataStore.open(databasePath: path);
      for (var i = 0; i < 10_000; i++) {
        await store.put(
          EntityState(
            userScope: 'alice',
            entityType: 'note',
            id: 'entity-$i',
            part: 'full',
            createdAtMs: i,
            lastEditedAtMs: i,
            revision: 1,
            sourceId: 'device',
            schemaVersion: 1,
            dirty: i.isEven,
          ),
        );
      }
      await store.close();

      final reopenWatch = Stopwatch()..start();
      final reopened = await SembastMetadataStore.open(databasePath: path);
      reopenWatch.stop();

      final batchWatch = Stopwatch()..start();
      await reopened.dirtyBatch(userScope: 'alice', limit: 50);
      batchWatch.stop();
      await reopened.close();

      final bytes = File(path).lengthSync();
      stdout.writeln('file_bytes=$bytes');
      stdout.writeln('reopen_ms=${reopenWatch.elapsedMilliseconds}');
      stdout.writeln('dirty_batch_ms=${batchWatch.elapsedMilliseconds}');
    },
    skip: _enabled ? null : 'run with --dart-define=ULSYNC_MEASURE=true',
  );
}

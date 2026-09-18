/// Record kits are **indivisible** and **complete**: never split across a
/// SPEC batch of 500, and never missing a cell because `full` already ran.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ulsync/src/engine/record_kit.dart';
import 'package:ulsync/src/store/entity_state.dart';
import 'package:ulsync/ulsync.dart';

EntityState _dirty({
  required String id,
  String part = 'full',
  String entityType = 'task',
  int createdAtMs = 1,
  int lastEditedAtMs = 1,
}) {
  return EntityState(
    userScope: 'alice',
    entityType: entityType,
    id: id,
    part: part,
    createdAtMs: createdAtMs,
    lastEditedAtMs: lastEditedAtMs,
    revision: 1,
    sourceId: 'device-a',
    schemaVersion: 1,
    dirty: true,
  );
}

Envelope _env({
  required String id,
  required String part,
  required int serverSeq,
  String entityType = 'task',
}) {
  return Envelope(
    id: id,
    part: part,
    entityType: entityType,
    createdAtMs: 1,
    lastEditedAtMs: 1,
    revision: 1,
    sourceId: 'device-a',
    flags: 0,
    schemaVersion: 1,
    payloadEncoding: 'json',
    payload: Uint8List(0),
    serverSeq: serverSeq,
  );
}

DiffProbe _probe({required String id, required String part}) {
  return DiffProbe(
    id: id,
    part: part,
    lastEditedAtMs: 1,
    revision: 1,
    sourceId: 'device-a',
  );
}

void main() {
  test(
    'packCompleteRecordKits keeps full and done of one id under the ceiling',
    () {
      final packed = packCompleteRecordKits([
        _dirty(id: 't1', part: 'full', lastEditedAtMs: 1),
        _dirty(id: 't2', part: 'full', lastEditedAtMs: 2),
        _dirty(id: 't3', part: 'full', lastEditedAtMs: 3),
        _dirty(id: 't1', part: 'done', lastEditedAtMs: 4),
      ], limit: 3);
      expect(packed.map((row) => '${row.id}:${row.part}'), [
        't1:full',
        't1:done',
        't2:full',
      ]);
    },
  );

  test('packCompleteRecordKits orders a kit by createdAtMs', () {
    final packed = packCompleteRecordKits([
      _dirty(id: 't1', part: 'done', createdAtMs: 30, lastEditedAtMs: 1),
      _dirty(id: 't1', part: 'full', createdAtMs: 10, lastEditedAtMs: 2),
      _dirty(id: 't1', part: 'deleted', createdAtMs: 20, lastEditedAtMs: 3),
    ], limit: 3);
    expect(packed.map((row) => row.part), ['full', 'deleted', 'done']);
  });

  test(
    'packCompleteRecordKits throws when one kit is larger than the ceiling',
    () {
      expect(
        () => packCompleteRecordKits([
          _dirty(id: 't1', part: 'full'),
          _dirty(id: 't1', part: 'done'),
          _dirty(id: 't1', part: 'deleted'),
        ], limit: 2),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('must not split a record kit'),
          ),
        ),
      );
    },
  );

  test(
    'packCompleteDiffKits keeps both parts of one id in the same request',
    () {
      final batches = packCompleteDiffKits([
        _probe(id: 'a', part: 'full'),
        _probe(id: 'b', part: 'full'),
        _probe(id: 'c', part: 'full'),
        _probe(id: 'a', part: 'done'),
      ], limit: 3);
      expect(batches, hasLength(2));
      expect(batches[0].map((p) => '${p.id}:${p.part}'), [
        'a:full',
        'a:done',
        'b:full',
      ]);
      expect(batches[1].map((p) => '${p.id}:${p.part}'), ['c:full']);
    },
  );

  test('pullIngestLength holds the trailing id of a full page', () {
    final page = [
      _env(id: 'n1', part: 'full', serverSeq: 1),
      _env(id: 'n2', part: 'full', serverSeq: 2),
      _env(id: 't1', part: 'full', serverSeq: 3),
      _env(id: 't1', part: 'done', serverSeq: 4),
    ];
    expect(pullIngestLength(page, 4), 2);
    expect(trailingRecordKitStart(page), 2);
  });

  test('pullIngestLength ingests a short page whole', () {
    final page = [
      _env(id: 'n1', part: 'full', serverSeq: 1),
      _env(id: 't1', part: 'full', serverSeq: 2),
    ];
    expect(pullIngestLength(page, 4), 2);
  });

  test('pullIngestLength ingests a full page that is one id', () {
    final page = [
      _env(id: 't1', part: 'full', serverSeq: 1),
      _env(id: 't1', part: 'done', serverSeq: 2),
      _env(id: 't1', part: 'deleted', serverSeq: 3),
    ];
    expect(pullIngestLength(page, 3), 3);
  });
}

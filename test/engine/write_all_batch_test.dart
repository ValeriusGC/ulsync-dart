/// Batch push and [UlsyncClient.writeAll]: one POST, one lock, dirty after 200.
///
/// A related edit must not leave on the wire until every persist finished.
/// A drain of the dirty queue must not clear marks before the POST returns.
/// A record kit (`full` plus named parts of one id) is **indivisible**: the
/// SPEC ceiling of 500 must not cut it in half.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:ulsync/src/store/entity_state.dart';
import 'package:ulsync/src/store/sembast_metadata_store.dart';
import 'package:ulsync/ulsync.dart';

import 'fake_sync_transport.dart';

/// Monotonic suffix so parallel tests never share a database name.
var _pathCounter = 0;

/// Test entity: id plus text so [EntityAdapter.apply] can upsert by id.
final class _Memo {
  /// Creates a memo with a stable [id].
  const _Memo({required this.id, required this.text});

  /// Wire `id`.
  final String id;

  /// Application payload text.
  final String text;
}

/// JSON payload bytes for [_Memo], including [id] so decode can rebuild it.
Uint8List _memoBytes({required String id, required String text}) {
  return Uint8List.fromList(utf8.encode(jsonEncode({'id': id, 'text': text})));
}

/// Rebuilds a [_Memo] from [_memoBytes].
_Memo _memoFrom(Uint8List bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map) {
    throw StateError('memo payload is not an object');
  }
  final map = Map<String, Object?>.from(decoded);
  return _Memo(id: map['id']! as String, text: map['text']! as String);
}

/// Application row with snapshot, checkbox, and hide columns.
final class _Task {
  /// Creates a task. Slice fields start false.
  _Task({required this.id, this.title = ''});

  /// Wire `id`.
  final String id;

  /// Snapshot column.
  String title;

  /// Checkbox column.
  bool done = false;

  /// Hide column.
  bool deleted = false;
}

/// JSON payload for a full snapshot.
Uint8List _fullBytes({required String id, required String title}) {
  return Uint8List.fromList(
    utf8.encode(jsonEncode({'id': id, 'title': title})),
  );
}

/// Rebuilds a [_Task] from [_fullBytes].
_Task _taskFromFull(Uint8List bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map) {
    throw StateError('full payload is not an object');
  }
  final map = Map<String, Object?>.from(decoded);
  return _Task(id: map['id']! as String, title: map['title']! as String);
}

/// JSON bool payload for `done` or `deleted`.
Uint8List _flagBytes(bool value) {
  return Uint8List.fromList(utf8.encode(jsonEncode(value)));
}

/// Reads a JSON bool payload.
bool _flagFrom(Uint8List bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! bool) {
    throw StateError('flag payload is not a bool');
  }
  return decoded;
}

/// Note client, in-memory domain, and a fake transport.
final class _NoteHarness {
  /// Creates a harness. Prefer [_NoteHarness.open].
  _NoteHarness({
    required this.store,
    required this.fake,
    required this.client,
    required this.appStore,
  });

  /// Real sembast metadata store (in memory).
  final SembastMetadataStore store;

  /// Scripted transport. No HTTP.
  final FakeSyncTransport fake;

  /// Client under test.
  final UlsyncClient client;

  /// Application records keyed by id.
  final Map<String, String> appStore;

  /// Opens a note client with an injected fake transport.
  static Future<_NoteHarness> open() async {
    final factory = databaseFactoryMemory;
    final path = 'write_all_notes_${_pathCounter++}';
    await factory.deleteDatabase(path);

    final fake = FakeSyncTransport();
    final appStore = <String, String>{};
    final client = await UlsyncClient.open(
      name: path,
      baseUrl: Uri.parse('http://engine.test'),
      origin: 'com.example.app/7c3e9a12-4b56-4d8e-9f01-2a3b4c5d6e7f',
      userScope: 'alice',
      sourceId: 'device-a',
      tokenProvider: () async => 'test-token',
      adapters: [
        EntityAdapter<_Memo>(
          entityType: 'note',
          schemaVersion: 1,
          encode: (memo) => _memoBytes(id: memo.id, text: memo.text),
          decode: (bytes, schemaVersion) => _memoFrom(bytes),
          load: (id) async {
            final text = appStore[id];
            if (text == null) {
              return null;
            }
            return _Memo(id: id, text: text);
          },
          apply: (memo, meta) async {
            appStore[memo.id] = memo.text;
          },
          listIds: () async => appStore.keys.toList(growable: false),
        ),
      ],
      transport: fake,
      inMemory: true,
    );
    final store = await SembastMetadataStore.open(
      databasePath: path,
      factory: factory,
    );
    addTearDown(() async {
      await client.close();
      await factory.deleteDatabase(path);
    });

    return _NoteHarness(
      store: store,
      fake: fake,
      client: client,
      appStore: appStore,
    );
  }

  /// Dirty metadata rows for this user.
  Future<List<EntityState>> dirtyRows() {
    return store.dirtyBatch(userScope: 'alice', limit: 500);
  }

  /// Metadata row for [id], or `null`.
  Future<EntityState?> stateOf(String id, {String part = 'full'}) {
    return store.stateOf(
      userScope: 'alice',
      entityType: 'note',
      id: id,
      part: part,
    );
  }
}

/// Task client with [EntityAdapter.encodePart] for `done` and `deleted`.
final class _TaskHarness {
  /// Creates a harness. Prefer [_TaskHarness.open].
  _TaskHarness({
    required this.fake,
    required this.client,
    required this.domain,
  });

  /// Scripted transport. No HTTP.
  final FakeSyncTransport fake;

  /// Client under test.
  final UlsyncClient client;

  /// Application rows keyed by id.
  final Map<String, _Task> domain;

  /// Opens a three-column task client.
  static Future<_TaskHarness> open({int pushBatchLimit = 500}) async {
    final factory = databaseFactoryMemory;
    final path = 'write_all_tasks_${_pathCounter++}';
    await factory.deleteDatabase(path);

    final fake = FakeSyncTransport();
    final domain = <String, _Task>{};
    final client = await UlsyncClient.open(
      name: path,
      baseUrl: Uri.parse('http://engine.test'),
      origin: 'com.example.app/7c3e9a12-4b56-4d8e-9f01-2a3b4c5d6e7f',
      userScope: 'alice',
      sourceId: 'device-a',
      tokenProvider: () async => 'test-token',
      adapters: [
        EntityAdapter<_Task>(
          entityType: 'task',
          schemaVersion: 1,
          encode: (task) => _fullBytes(id: task.id, title: task.title),
          decode: (bytes, schemaVersion) => _taskFromFull(bytes),
          load: (id) async => domain[id],
          apply: (task, meta) async {
            final row = domain.putIfAbsent(task.id, () => _Task(id: task.id));
            row.title = task.title;
          },
          listIds: () async => domain.keys.toList(growable: false),
          encodePart: (id, part) async {
            final row = domain[id];
            if (row == null) {
              return null;
            }
            switch (part) {
              case 'done':
                return _flagBytes(row.done);
              case 'deleted':
                return _flagBytes(row.deleted);
              default:
                return null;
            }
          },
          applyPart: (id, part, payload, meta) async {
            final row = domain.putIfAbsent(id, () => _Task(id: id));
            switch (part) {
              case 'done':
                row.done = _flagFrom(payload);
              case 'deleted':
                row.deleted = _flagFrom(payload);
            }
          },
        ),
      ],
      transport: fake,
      inMemory: true,
      pushBatchLimit: pushBatchLimit,
    );
    addTearDown(() async {
      await client.close();
      await factory.deleteDatabase(path);
    });

    return _TaskHarness(fake: fake, client: client, domain: domain);
  }
}

void main() {
  test(
    'writeAll of 100 full rows posts them in one push of length 100',
    () async {
      final h = await _NoteHarness.open();
      final persistStarted = List<bool>.filled(100, false);
      final firstEntered = Completer<void>();
      final firstHold = Completer<void>();
      var pushWhileFirstHeld = false;
      h.fake.onBeforePush = () {
        if (!firstHold.isCompleted) {
          pushWhileFirstHeld = true;
        }
      };

      final writeAllFuture = h.client.writeAll([
        for (var i = 0; i < 100; i++)
          WriteOp(
            entityType: 'note',
            id: 'n$i',
            persist: () async {
              persistStarted[i] = true;
              if (i == 0) {
                firstEntered.complete();
                await firstHold.future;
              }
              h.appStore['n$i'] = 't$i';
            },
          ),
      ]);

      await firstEntered.future;
      expect(persistStarted[99], isFalse);
      final syncFuture = h.client.syncOnce();
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(h.fake.pushCalls, isEmpty);
      expect(pushWhileFirstHeld, isFalse);
      expect(persistStarted[99], isFalse);

      firstHold.complete();
      await writeAllFuture;
      expect(persistStarted.every((started) => started), isTrue);
      await syncFuture;

      expect(h.fake.pushCalls, hasLength(1));
      expect(h.fake.pushCalls.single, hasLength(100));
      expect(pushWhileFirstHeld, isFalse);
      final ids = h.fake.pushCalls.single.map((e) => e.id).toSet();
      expect(ids, hasLength(100));
      expect(await h.dirtyRows(), isEmpty);
    },
  );

  test(
    'three dirty cells of different parts leave in one push of length 3',
    () async {
      final h = await _TaskHarness.open();
      await h.client.write<void>(
        entityType: 'task',
        id: 't1',
        persist: () async {
          h.domain['t1'] = _Task(id: 't1', title: 'Buy milk');
        },
      );
      await h.client.write<void>(
        entityType: 'task',
        id: 't1',
        part: 'done',
        persist: () async {
          h.domain['t1']!.done = true;
        },
      );
      await h.client.write<void>(
        entityType: 'task',
        id: 't1',
        part: 'deleted',
        persist: () async {
          h.domain['t1']!.deleted = true;
        },
      );

      final report = await h.client.syncOnce();
      expect(h.fake.pushCalls, hasLength(1));
      expect(h.fake.pushCalls.single, hasLength(3));
      final parts = h.fake.pushCalls.single.map((e) => e.part).toList();
      expect(parts, containsAll(['full', 'done', 'deleted']));
      expect(h.fake.pushCalls.single.map((e) => e.id).toSet(), {'t1'});
      expect(report.pushed, 3);
      expect(report.accepted, 3);
    },
  );

  test(
    'push keeps full and done of one id together under the batch ceiling',
    () async {
      final h = await _TaskHarness.open(pushBatchLimit: 3);
      await h.client.write<void>(
        entityType: 'task',
        id: 't1',
        persist: () async {
          h.domain['t1'] = _Task(id: 't1', title: 'One');
        },
      );
      await h.client.write<void>(
        entityType: 'task',
        id: 't2',
        persist: () async {
          h.domain['t2'] = _Task(id: 't2', title: 'Two');
        },
      );
      await h.client.write<void>(
        entityType: 'task',
        id: 't3',
        persist: () async {
          h.domain['t3'] = _Task(id: 't3', title: 'Three');
        },
      );
      await h.client.write<void>(
        entityType: 'task',
        id: 't1',
        part: 'done',
        persist: () async {
          h.domain['t1']!.done = true;
        },
      );

      await h.client.syncOnce();
      expect(h.fake.pushCalls, hasLength(1));
      expect(h.fake.pushCalls.single.map((e) => '${e.id}:${e.part}'), [
        't1:full',
        't1:done',
        't2:full',
      ]);

      await h.client.syncOnce();
      expect(h.fake.pushCalls, hasLength(2));
      expect(h.fake.pushCalls[1].map((e) => '${e.id}:${e.part}'), ['t3:full']);
    },
  );

  test('throw on push leaves three dirty rows in place', () async {
    final h = await _NoteHarness.open();
    for (final id in ['a', 'b', 'c']) {
      await h.client.write<void>(
        entityType: 'note',
        id: id,
        persist: () async {
          h.appStore[id] = id;
        },
      );
    }
    h.fake.onPush = (_) async {
      throw StateError('push failed');
    };
    await expectLater(
      h.client.syncOnce(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'push failed',
        ),
      ),
    );
    expect(h.fake.pushCalls, hasLength(1));
    expect(h.fake.pushCalls.single, hasLength(3));
    final dirty = await h.dirtyRows();
    expect(dirty.map((row) => row.id).toSet(), {'a', 'b', 'c'});
    expect(dirty.every((row) => row.dirty), isTrue);
  });

  test('short push results are a protocol error and leave dirty set', () async {
    final h = await _NoteHarness.open();
    for (final id in ['a', 'b', 'c']) {
      await h.client.write<void>(
        entityType: 'note',
        id: id,
        persist: () async {
          h.appStore[id] = id;
        },
      );
    }
    h.fake.onPush = (envelopes) async {
      return [
        PushResult(
          id: envelopes.first.id,
          part: envelopes.first.part,
          applied: true,
        ),
      ];
    };
    await expectLater(
      h.client.syncOnce(),
      throwsA(
        isA<UlsyncProtocolException>().having(
          (error) => error.field,
          'field',
          'results',
        ),
      ),
    );
    expect(h.fake.pushCalls, hasLength(1));
    expect(h.fake.pushCalls.single, hasLength(3));
    final dirty = await h.dirtyRows();
    expect(dirty, hasLength(3));
  });

  test(
    'writeAll of two ids runs persist in order and both stay dirty',
    () async {
      final h = await _NoteHarness.open();
      var secondStarted = false;
      var firstFinished = false;
      await h.client.writeAll([
        WriteOp(
          entityType: 'note',
          id: 'a',
          persist: () async {
            await Future<void>.delayed(Duration.zero);
            expect(secondStarted, isFalse);
            firstFinished = true;
            h.appStore['a'] = 'one';
          },
        ),
        WriteOp(
          entityType: 'note',
          id: 'b',
          persist: () async {
            secondStarted = true;
            expect(firstFinished, isTrue);
            h.appStore['b'] = 'two';
          },
        ),
      ]);
      expect(secondStarted, isTrue);
      expect((await h.stateOf('a'))!.dirty, isTrue);
      expect((await h.stateOf('b'))!.dirty, isTrue);
      expect(h.fake.pushCalls, isEmpty);
    },
  );

  test('HTTP 413 does not issue a second push of length 1', () async {
    final h = await _NoteHarness.open();
    for (final id in ['a', 'b', 'c']) {
      await h.client.write<void>(
        entityType: 'note',
        id: id,
        persist: () async {
          h.appStore[id] = id;
        },
      );
    }
    h.fake.onPush = (_) async {
      throw const UlsyncRequestRejected('payload too large', statusCode: 413);
    };
    await expectLater(
      h.client.syncOnce(),
      throwsA(
        isA<UlsyncRequestRejected>().having(
          (error) => error.statusCode,
          'statusCode',
          413,
        ),
      ),
    );
    expect(h.fake.pushCalls, hasLength(1));
    expect(h.fake.pushCalls.single, hasLength(3));
    expect(h.fake.pushCalls.where((call) => call.length == 1), isEmpty);
    expect(await h.dirtyRows(), hasLength(3));
  });

  test('writeAll of an empty list is a no-op', () async {
    final h = await _NoteHarness.open();
    await h.client.writeAll(const <WriteOp>[]);
    expect(h.fake.pushCalls, isEmpty);
    expect(await h.dirtyRows(), isEmpty);
  });

  test(
    'writeAll persist throw on the second item leaves 1–2 marked and skips 3',
    () async {
      final h = await _NoteHarness.open();
      var thirdStarted = false;
      await expectLater(
        h.client.writeAll([
          WriteOp(
            entityType: 'note',
            id: 'a',
            persist: () async {
              h.appStore['a'] = 'one';
            },
          ),
          WriteOp(
            entityType: 'note',
            id: 'b',
            persist: () async {
              throw StateError('persist failed');
            },
          ),
          WriteOp(
            entityType: 'note',
            id: 'c',
            persist: () async {
              thirdStarted = true;
              h.appStore['c'] = 'three';
            },
          ),
        ]),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'persist failed',
          ),
        ),
      );
      expect(thirdStarted, isFalse);
      expect(h.appStore.containsKey('c'), isFalse);
      expect((await h.stateOf('a'))!.dirty, isTrue);
      expect((await h.stateOf('b'))!.dirty, isTrue);
      expect(await h.stateOf('c'), isNull);
    },
  );
}

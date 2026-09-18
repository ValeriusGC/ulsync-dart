/// Frozen catch-up and lock tests for a downed store with live running.
///
/// Names are literal: `accept_34.sh` greps them. Engine tests open the
/// client only with `inMemory: true` so `path_provider` is never loaded
/// on the VM. Catch-up after [UlsyncClient.write] must not require the
/// test to call [UlsyncClient.syncOnce] while [UlsyncClient.live] is on.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:ulsync/src/engine/lww.dart';
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

/// Shared in-memory store used by two fakes in converge tests.
final class _Warehouse {
  /// When true, push and pull throw [UlsyncNetworkException].
  bool down = true;

  int _seq = 0;
  final Map<String, Envelope> _rows = {};
  final List<FakeSyncTransport> _clients = [];

  /// Wires [fake] so both clients share one last-write-wins map.
  ///
  /// A successful push is also forwarded as a live envelope to the other
  /// clients, the way a real store would appear on SSE. Pull alone can
  /// miss a neighbour that posted after this drain's pull.
  void bind(FakeSyncTransport fake) {
    _clients.add(fake);
    fake.onPush = (envelopes) async {
      if (down) {
        throw const UlsyncNetworkException('store down');
      }
      final results = <PushResult>[];
      for (final envelope in envelopes) {
        _seq++;
        final key = '${envelope.id}\u0000${envelope.part}';
        final existing = _rows[key];
        final applied =
            existing == null ||
            incomingWins(
              incomingLastEditedAtMs: envelope.lastEditedAtMs,
              incomingRevision: envelope.revision,
              incomingSourceId: envelope.sourceId,
              localLastEditedAtMs: existing.lastEditedAtMs,
              localRevision: existing.revision,
              localSourceId: existing.sourceId,
            );
        if (applied) {
          final stored = Envelope(
            id: envelope.id,
            part: envelope.part,
            entityType: envelope.entityType,
            createdAtMs: envelope.createdAtMs,
            lastEditedAtMs: envelope.lastEditedAtMs,
            revision: envelope.revision,
            sourceId: envelope.sourceId,
            flags: envelope.flags,
            schemaVersion: envelope.schemaVersion,
            payloadEncoding: envelope.payloadEncoding,
            payload: envelope.payload,
            serverSeq: _seq,
          );
          _rows[key] = stored;
          for (final other in _clients) {
            if (identical(other, fake) ||
                other.closed ||
                other.liveController.isClosed) {
              continue;
            }
            other.liveController.add(LiveEnvelope(stored));
          }
        }
        results.add(
          PushResult(id: envelope.id, part: envelope.part, applied: applied),
        );
      }
      return results;
    };
    fake.onPull = ({required int since, int? limit}) async {
      if (down) {
        throw const UlsyncNetworkException('store down');
      }
      final listed =
          _rows.values
              .where((envelope) => (envelope.serverSeq ?? 0) > since)
              .toList()
            ..sort((a, b) => (a.serverSeq ?? 0).compareTo(b.serverSeq ?? 0));
      final take = limit == null ? listed : listed.take(limit).toList();
      final next = take.isEmpty ? since : take.last.serverSeq!;
      return PullPage(envelopes: take, nextCursor: next);
    };
  }
}

/// Note client, in-memory domain, and a fake transport.
final class _Harness {
  /// Creates a harness. Prefer [_Harness.open].
  _Harness({
    required this.name,
    required this.store,
    required this.fake,
    required this.client,
    required this.appStore,
  });

  /// In-memory database name, reused across close/open of the same instance.
  final String name;

  /// Real sembast metadata store (in memory).
  final SembastMetadataStore store;

  /// Scripted transport. No HTTP.
  final FakeSyncTransport fake;

  /// Client under test.
  final UlsyncClient client;

  /// Application records keyed by id.
  final Map<String, String> appStore;

  /// Opens a note client with an injected fake transport.
  static Future<_Harness> open({
    String? name,
    String sourceId = 'device-a',
    Map<String, String>? appStore,
    bool deleteExisting = true,
    FakeSyncTransport? fake,
  }) async {
    final factory = databaseFactoryMemory;
    final path = name ?? 'offline_queue_${_pathCounter++}';
    if (deleteExisting) {
      await factory.deleteDatabase(path);
    }
    final transport = fake ?? FakeSyncTransport();
    final domain = appStore ?? <String, String>{};
    final client = await UlsyncClient.open(
      name: path,
      baseUrl: Uri.parse('http://engine.test'),
      origin: 'com.example.app/7c3e9a12-4b56-4d8e-9f01-2a3b4c5d6e7f',
      userScope: 'alice',
      sourceId: sourceId,
      tokenProvider: () async => 'test-token',
      adapters: [
        EntityAdapter<_Memo>(
          entityType: 'note',
          schemaVersion: 1,
          encode: (memo) => _memoBytes(id: memo.id, text: memo.text),
          decode: (bytes, schemaVersion) => _memoFrom(bytes),
          load: (id) async {
            final text = domain[id];
            if (text == null) {
              return null;
            }
            return _Memo(id: id, text: text);
          },
          apply: (memo, meta) async {
            domain[memo.id] = memo.text;
          },
          listIds: () async => domain.keys.toList(growable: false),
        ),
      ],
      transport: transport,
      inMemory: true,
      catchUpRetryDelay: Duration.zero,
    );
    final store = await SembastMetadataStore.open(
      databasePath: path,
      factory: factory,
    );
    addTearDown(() async {
      await client.close();
      await store.close();
    });
    return _Harness(
      name: path,
      store: store,
      fake: transport,
      client: client,
      appStore: domain,
    );
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

  /// Starts [UlsyncClient.live] and waits until the fake captured callbacks.
  Future<void> startLive() async {
    client.live().listen((_) {});
    await _pumpUntil(() => fake.appliedSince != null);
  }

  /// Persists [text] for [id] through [UlsyncClient.write].
  Future<void> writeNote(String id, String text) {
    return client.write<void>(
      entityType: 'note',
      id: id,
      persist: () async {
        appStore[id] = text;
      },
    );
  }
}

/// Task client with [EntityAdapter.encodePart] for `done` and `deleted`.
final class _TaskHarness {
  /// Creates a harness. Prefer [_TaskHarness.open].
  _TaskHarness({
    required this.store,
    required this.fake,
    required this.client,
    required this.domain,
  });

  /// Real sembast metadata store (in memory).
  final SembastMetadataStore store;

  /// Scripted transport. No HTTP.
  final FakeSyncTransport fake;

  /// Client under test.
  final UlsyncClient client;

  /// Application rows keyed by id.
  final Map<String, _Task> domain;

  /// Opens a three-column task client.
  static Future<_TaskHarness> open() async {
    final factory = databaseFactoryMemory;
    final path = 'offline_queue_tasks_${_pathCounter++}';
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
                row.done = jsonDecode(utf8.decode(payload)) as bool;
              case 'deleted':
                row.deleted = jsonDecode(utf8.decode(payload)) as bool;
            }
          },
        ),
      ],
      transport: fake,
      inMemory: true,
      catchUpRetryDelay: Duration.zero,
    );
    final store = await SembastMetadataStore.open(
      databasePath: path,
      factory: factory,
    );
    addTearDown(() async {
      await client.close();
      await store.close();
    });
    return _TaskHarness(
      store: store,
      fake: fake,
      client: client,
      domain: domain,
    );
  }

  /// Metadata row for [id] and [part], or `null`.
  Future<EntityState?> stateOf(String id, {required String part}) {
    return store.stateOf(
      userScope: 'alice',
      entityType: 'task',
      id: id,
      part: part,
    );
  }
}

/// Yields the event loop until [condition] is true, at most [max] times.
Future<void> _pumpUntil(bool Function() condition, {int max = 200}) async {
  for (var i = 0; i < max; i++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition not met after $max event-loop yields');
}

/// Same as [_pumpUntil] for an async condition.
///
/// [FakeSyncTransport.push] records the call (and a scripted [onPush]
/// counter) **before** the engine re-takes the serial lock to clear dirty.
/// Waiting only on the counter races on a loaded CI runner.
Future<void> _pumpUntilAsync(
  Future<bool> Function() condition, {
  int max = 200,
}) async {
  for (var i = 0; i < max; i++) {
    if (await condition()) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('async condition not met after $max event-loop yields');
}

/// Whether [id] exists in [h] and is no longer dirty.
Future<bool> _isClean(_Harness h, String id) async {
  final row = await h.stateOf(id);
  return row != null && !row.dirty;
}

void main() {
  test(
    'write returns after persist when push throws; dirty stays; write does not throw',
    () async {
      final h = await _Harness.open();
      h.fake.onPush = (_) async {
        throw const UlsyncNetworkException('store down');
      };
      await h.startLive();
      await h.writeNote('e1', 'Milk');
      expect(h.appStore['e1'], 'Milk');
      await _pumpUntil(() => h.fake.pushCalls.isNotEmpty);
      expect((await h.stateOf('e1'))!.dirty, isTrue);
    },
  );

  test(
    'writeAll of a three-cell kit leaves every cell dirty when push throws',
    () async {
      final h = await _TaskHarness.open();
      h.fake.onPush = (_) async {
        throw const UlsyncNetworkException('store down');
      };
      h.client.live().listen((_) {});
      await _pumpUntil(() => h.fake.appliedSince != null);
      await h.client.writeAll([
        WriteOp(
          entityType: 'task',
          id: 't1',
          persist: () async {
            h.domain['t1'] = _Task(id: 't1', title: 'Milk');
          },
        ),
        WriteOp(
          entityType: 'task',
          id: 't1',
          part: 'done',
          persist: () async {
            h.domain['t1']!.done = true;
          },
        ),
        WriteOp(
          entityType: 'task',
          id: 't1',
          part: 'deleted',
          persist: () async {
            h.domain['t1']!.deleted = true;
          },
        ),
      ]);
      await _pumpUntil(() => h.fake.pushCalls.isNotEmpty);
      expect(h.fake.pushCalls.single, hasLength(3));
      expect((await h.stateOf('t1', part: 'full'))!.dirty, isTrue);
      expect((await h.stateOf('t1', part: 'done'))!.dirty, isTrue);
      expect((await h.stateOf('t1', part: 'deleted'))!.dirty, isTrue);
    },
  );

  test('write completes while push never returns', () async {
    final h = await _Harness.open();
    final hang = Completer<List<PushResult>>();
    addTearDown(() {
      if (!hang.isCompleted) {
        hang.complete([PushResult(id: 'e1', part: 'full', applied: true)]);
      }
    });
    h.fake.onPush = (_) => hang.future;
    await h.startLive();
    await h.writeNote('e1', 'Milk');
    await _pumpUntil(() => h.fake.pushCalls.isNotEmpty);
    final secondWrite = h.writeNote('e2', 'Bread');
    await expectLater(
      secondWrite,
      completes,
    ).timeout(const Duration(seconds: 1));
    expect(hang.isCompleted, isFalse);
    expect(h.appStore['e2'], 'Bread');
  });

  test(
    'live running: write drains without the test calling syncOnce',
    () async {
      final h = await _Harness.open();
      await h.startLive();
      await h.writeNote('e1', 'Milk');
      await _pumpUntil(() => h.fake.pushCalls.isNotEmpty);
      expect(h.fake.pushCalls.single.single.id, 'e1');
      await _pumpUntilAsync(() => _isClean(h, 'e1'));
      expect((await h.stateOf('e1'))!.dirty, isFalse);
    },
  );

  test('live not started: write does not call push', () async {
    final h = await _Harness.open();
    await h.writeNote('e1', 'Milk');
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(h.fake.pushCalls, isEmpty);
    expect((await h.stateOf('e1'))!.dirty, isTrue);
  });

  test(
    'SyncConnectionRestored drains queued writes without the test calling syncOnce',
    () async {
      final h = await _Harness.open();
      await h.writeNote('e1', 'Milk');
      expect(h.fake.pushCalls, isEmpty);
      await h.startLive();
      expect(h.fake.pushCalls, isEmpty);
      h.fake.onConnectionState!(LiveConnectionState.restored);
      await _pumpUntil(() => h.fake.pushCalls.isNotEmpty);
      expect(h.fake.pushCalls.single.single.id, 'e1');
      await _pumpUntilAsync(() => _isClean(h, 'e1'));
      expect((await h.stateOf('e1'))!.dirty, isFalse);
    },
  );

  test(
    'two clients survive a downed push then converge on different ids',
    () async {
      final warehouse = _Warehouse();
      final a = await _Harness.open(sourceId: 'device-a');
      final b = await _Harness.open(sourceId: 'device-b');
      warehouse.bind(a.fake);
      warehouse.bind(b.fake);
      await a.startLive();
      await b.startLive();
      await a.writeNote('e1', 'Milk');
      await b.writeNote('e2', 'Bread');
      warehouse.down = false;
      await _pumpUntil(
        () => a.appStore['e2'] == 'Bread' && b.appStore['e1'] == 'Milk',
        max: 400,
      );
      expect(a.appStore['e1'], 'Milk');
      expect(b.appStore['e2'], 'Bread');
    },
  );

  test(
    'two clients same cell: later lastEditedAt wins after both pushes failed',
    () async {
      final warehouse = _Warehouse();
      final a = await _Harness.open(sourceId: 'device-a');
      final b = await _Harness.open(sourceId: 'device-b');
      warehouse.bind(a.fake);
      warehouse.bind(b.fake);
      await a.startLive();
      await b.startLive();
      await a.writeNote('e1', 'first');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await b.writeNote('e1', 'second');
      warehouse.down = false;
      await _pumpUntil(
        () => a.appStore['e1'] == 'second' && b.appStore['e1'] == 'second',
        max: 400,
      );
      expect(a.appStore['e1'], isNot(contains('firstsecond')));
      expect(b.appStore['e1'], isNot(contains('firstsecond')));
    },
  );

  test('close then open same inMemory name keeps dirty and load', () async {
    final name = 'offline_reopen_${_pathCounter++}';
    final appStore = <String, String>{};
    final first = await _Harness.open(name: name, appStore: appStore);
    await first.writeNote('e1', 'Milk');
    expect((await first.stateOf('e1'))!.dirty, isTrue);
    await first.client.close();
    await first.store.close();

    final second = await _Harness.open(
      name: name,
      appStore: appStore,
      deleteExisting: false,
    );
    expect(second.appStore['e1'], 'Milk');
    expect((await second.stateOf('e1'))!.dirty, isTrue);
    await second.client.syncOnce();
    expect(second.fake.pushCalls, isNotEmpty);
    expect(second.fake.pushCalls.single.single.id, 'e1');
  });

  test(
    'Unauthorized on drain stops retry; network error keeps retrying',
    () async {
      final unauthorized = await _Harness.open();
      var unauthorizedPushes = 0;
      unauthorized.fake.onPush = (_) async {
        unauthorizedPushes++;
        throw const UlsyncUnauthorized('token rejected', statusCode: 401);
      };
      await unauthorized.startLive();
      await unauthorized.writeNote('e1', 'Milk');
      await _pumpUntil(() => unauthorizedPushes >= 1);
      final afterStop = unauthorizedPushes;
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(unauthorizedPushes, afterStop);
      expect((await unauthorized.stateOf('e1'))!.dirty, isTrue);

      final network = await _Harness.open();
      var networkPushes = 0;
      network.fake.onPush = (envelopes) async {
        networkPushes++;
        if (networkPushes == 1) {
          throw const UlsyncNetworkException('store down');
        }
        return [
          for (final envelope in envelopes)
            PushResult(id: envelope.id, part: envelope.part, applied: true),
        ];
      };
      await network.startLive();
      await network.writeNote('e1', 'Milk');
      await _pumpUntilAsync(() async {
        return networkPushes >= 2 && await _isClean(network, 'e1');
      });
      expect(networkPushes, greaterThanOrEqualTo(2));
      expect((await network.stateOf('e1'))!.dirty, isFalse);
    },
  );

  test('posted revision that changed during push is not cleared', () async {
    final h = await _Harness.open();
    h.fake.onPush = (envelopes) async {
      if (envelopes.single.revision == 1) {
        await h.writeNote('e1', 'v2');
      }
      return [
        for (final envelope in envelopes)
          PushResult(id: envelope.id, part: envelope.part, applied: true),
      ];
    };
    await h.startLive();
    await h.writeNote('e1', 'v1');
    await _pumpUntil(() => h.fake.pushCalls.isNotEmpty);
    await _pumpUntil(() {
      return h.fake.pushCalls.any(
        (call) => call.any((envelope) => envelope.revision == 2),
      );
    });
    await _pumpUntilAsync(() => _isClean(h, 'e1'));
    expect(h.appStore['e1'], 'v2');
    expect(
      h.fake.pushCalls.any(
        (call) => call.any((envelope) => envelope.revision == 1),
      ),
      isTrue,
    );
    expect((await h.stateOf('e1'))!.dirty, isFalse);
  });
}

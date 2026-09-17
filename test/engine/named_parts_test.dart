/// Column-apply tests: named parts are independent cells, not one winner
/// per record.
///
/// The test domain has three columns — `title`, `done`, `deleted`.
/// [EntityAdapter.apply] of `full` writes **only** `title`.
/// [EntityAdapter.applyPart] for `done` writes only `done`.
/// [EntityAdapter.applyPart] for `deleted` writes only `deleted`.
/// Incoming `full` payloads still *carry* slice fields so a naive apply
/// that copied every JSON key would restore a hidden row; the spy and
/// the domain assertions both fail if that happens.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:ulsync/ulsync.dart';

import 'fake_sync_transport.dart';

/// Monotonic suffix so parallel tests never share a database name.
var _pathCounter = 0;

/// Application row with three columns that must not clobber each other.
final class _Task {
  /// Creates a task. Slice fields default to false, not "cleared by full".
  _Task({
    required this.id,
    this.title = '',
    this.done = false,
    this.deleted = false,
  });

  /// Wire `id`.
  final String id;

  /// Snapshot column. Only [EntityAdapter.apply] of `full` writes this.
  String title;

  /// Checkbox column. Only `applyPart('done')` writes this.
  bool done;

  /// Hide column. Only `applyPart('deleted')` writes this.
  bool deleted;
}

/// JSON payload for a full snapshot that **also** carries slice fields.
///
/// A naive `apply` that copied every JSON key would write `done` and
/// `deleted` from this object. The adapter under test must ignore them.
Uint8List _fullBytes({
  required String id,
  required String title,
  bool done = false,
  bool deleted = false,
}) {
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({'id': id, 'title': title, 'done': done, 'deleted': deleted}),
    ),
  );
}

/// Rebuilds a [_Task] from [_fullBytes], including slice fields in memory.
///
/// Decode may see every key. [EntityAdapter.apply] must still write only
/// [_Task.title].
_Task _taskFromFull(Uint8List bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map) {
    throw StateError('full payload is not an object');
  }
  final map = Map<String, Object?>.from(decoded);
  return _Task(
    id: map['id']! as String,
    title: map['title']! as String,
    done: map['done']! as bool,
    deleted: map['deleted']! as bool,
  );
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

/// Edit time that beats a local [UlsyncClient.write] stamp.
int _laterMs() => DateTime.now().millisecondsSinceEpoch + 60_000;

/// Incoming envelope for pull tests.
Envelope _partEnvelope({
  required String id,
  required String part,
  required int serverSeq,
  required Uint8List payload,
  int? lastEditedAtMs,
  int revision = 99,
  String sourceId = 'device-b',
}) {
  return Envelope(
    id: id,
    part: part,
    entityType: 'task',
    createdAtMs: 1000,
    lastEditedAtMs: lastEditedAtMs ?? _laterMs(),
    revision: revision,
    sourceId: sourceId,
    flags: 0,
    schemaVersion: 1,
    payloadEncoding: 'json',
    payload: payload,
    serverSeq: serverSeq,
  );
}

/// One client, spy counters, and an in-memory three-column store.
final class _Harness {
  /// Creates a harness. Prefer [_Harness.open].
  _Harness({
    required this.store,
    required this.fake,
    required this.client,
    required this.domain,
    required this.deletedWritesFromFullApply,
    required this.deletedWritesFromApplyPart,
    required this.doneWritesFromApplyPart,
  });

  /// Real sembast metadata store (in memory).
  final SembastMetadataStore store;

  /// Scripted transport. No HTTP.
  final FakeSyncTransport fake;

  /// Client under test.
  final UlsyncClient client;

  /// Application rows keyed by id.
  final Map<String, _Task> domain;

  /// Times `apply` of `full` changed [_Task.deleted]. Must stay 0.
  final List<int> deletedWritesFromFullApply;

  /// Times `applyPart('deleted')` assigned [_Task.deleted].
  final List<int> deletedWritesFromApplyPart;

  /// Times `applyPart('done')` assigned [_Task.done].
  final List<int> doneWritesFromApplyPart;

  /// Opens a client whose `apply` of `full` writes only [_Task.title].
  static Future<_Harness> open({
    Future<Uint8List?> Function(String id, String part)? encodePart,
    Future<void> Function(String id, String part, Uint8List payload)? applyPart,
    bool includePartCallbacks = true,
  }) async {
    final factory = databaseFactoryMemory;
    final path = 'named_parts_${_pathCounter++}.db';
    await factory.deleteDatabase(path);
    final store = await SembastMetadataStore.open(
      databasePath: path,
      factory: factory,
    );
    addTearDown(() async {
      await store.close();
      await factory.deleteDatabase(path);
    });

    final fake = FakeSyncTransport();
    final domain = <String, _Task>{};
    final deletedFromFull = <int>[0];
    final deletedFromPart = <int>[0];
    final doneFromPart = <int>[0];

    Future<void> defaultApplyPart(
      String id,
      String part,
      Uint8List payload,
    ) async {
      final row = domain.putIfAbsent(id, () => _Task(id: id));
      switch (part) {
        case 'done':
          doneFromPart[0]++;
          row.done = _flagFrom(payload);
        case 'deleted':
          deletedFromPart[0]++;
          row.deleted = _flagFrom(payload);
        default:
          break;
      }
    }

    final client = UlsyncClient(
      baseUrl: Uri.parse('http://engine.test'),
      origin: 'com.example.app/7c3e9a12-4b56-4d8e-9f01-2a3b4c5d6e7f',
      userScope: 'alice',
      sourceId: 'device-a',
      tokenProvider: () async => 'test-token',
      store: store,
      adapters: [
        EntityAdapter<_Task>(
          entityType: 'task',
          schemaVersion: 1,
          encode: (task) => _fullBytes(
            id: task.id,
            title: task.title,
            done: task.done,
            deleted: task.deleted,
          ),
          decode: (bytes, schemaVersion) => _taskFromFull(bytes),
          load: (id) async => domain[id],
          apply: (task) async {
            final existing = domain[task.id];
            final beforeDeleted = existing?.deleted;
            final row = existing ?? _Task(id: task.id);
            domain[task.id] = row;
            row.title = task.title;
            // Column apply: do not write slice fields from full.
            // `row.deleted = task.deleted` here would restore a hidden
            // row; the spy and the domain assertion both catch it.
            if (beforeDeleted != null && row.deleted != beforeDeleted) {
              deletedFromFull[0]++;
            }
          },
          encodePart: includePartCallbacks
              ? (encodePart ??
                    (id, part) async {
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
                    })
              : null,
          applyPart: includePartCallbacks
              ? (applyPart ?? defaultApplyPart)
              : null,
        ),
      ],
      transport: fake,
    );
    addTearDown(client.close);

    return _Harness(
      store: store,
      fake: fake,
      client: client,
      domain: domain,
      deletedWritesFromFullApply: deletedFromFull,
      deletedWritesFromApplyPart: deletedFromPart,
      doneWritesFromApplyPart: doneFromPart,
    );
  }

  /// Metadata row for [id] and [part], or `null`.
  Future<EntityState?> stateOf(String id, {String part = 'full'}) {
    return store.stateOf(
      userScope: 'alice',
      entityType: 'task',
      id: id,
      part: part,
    );
  }
}

void main() {
  test(
    'write without part records metadata with full (round-1a compatibility)',
    () async {
      final h = await _Harness.open();
      await h.client.write<void>(
        entityType: 'task',
        id: 't1',
        persist: () async {
          h.domain['t1'] = _Task(id: 't1', title: 'Buy milk');
        },
      );
      final full = await h.stateOf('t1');
      expect(full, isNotNull);
      expect(full!.part, 'full');
      expect(full.dirty, isTrue);
      expect(await h.stateOf('t1', part: 'done'), isNull);
    },
  );

  test(
    'write(part: done) without encodePart throws StateError and does not persist',
    () async {
      final h = await _Harness.open(includePartCallbacks: false);
      var persistCalled = false;
      await expectLater(
        h.client.write<void>(
          entityType: 'task',
          id: 't1',
          part: 'done',
          persist: () async {
            persistCalled = true;
            h.domain['t1'] = _Task(id: 't1', done: true);
          },
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('encodePart'),
          ),
        ),
      );
      expect(persistCalled, isFalse);
      expect(h.domain['t1'], isNull);
      expect(await h.stateOf('t1', part: 'done'), isNull);
      expect(await h.stateOf('t1'), isNull);
    },
  );

  test(
    'later done part does not clear deleted in the domain and the reverse',
    () async {
      final h = await _Harness.open();
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
        part: 'deleted',
        persist: () async {
          h.domain['t1']!.deleted = true;
        },
      );
      expect(h.domain['t1']!.deleted, isTrue);
      expect(h.domain['t1']!.done, isFalse);

      h.fake.onPull = ({required int since, int? limit}) async {
        if (since == 0) {
          return PullPage(
            envelopes: [
              _partEnvelope(
                id: 't1',
                part: 'done',
                serverSeq: 10,
                payload: _flagBytes(true),
              ),
            ],
            nextCursor: 10,
          );
        }
        return PullPage(envelopes: const [], nextCursor: since);
      };
      await h.client.syncOnce();
      expect(h.domain['t1']!.done, isTrue);
      expect(h.domain['t1']!.deleted, isTrue);
      expect(h.doneWritesFromApplyPart.first, 1);

      h.fake.onPull = ({required int since, int? limit}) async {
        if (since == 10) {
          return PullPage(
            envelopes: [
              _partEnvelope(
                id: 't1',
                part: 'deleted',
                serverSeq: 11,
                payload: _flagBytes(true),
              ),
            ],
            nextCursor: 11,
          );
        }
        return PullPage(envelopes: const [], nextCursor: since);
      };
      await h.client.syncOnce();
      expect(h.domain['t1']!.deleted, isTrue);
      expect(h.domain['t1']!.done, isTrue);
      expect(h.doneWritesFromApplyPart.first, 1);
    },
  );

  test(
    'incoming full after local deleted does not write the deleted field',
    () async {
      final h = await _Harness.open();
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
        part: 'deleted',
        persist: () async {
          h.domain['t1']!.deleted = true;
        },
      );
      expect(h.domain['t1']!.deleted, isTrue);

      h.fake.onPull = ({required int since, int? limit}) async {
        if (since == 0) {
          return PullPage(
            envelopes: [
              _partEnvelope(
                id: 't1',
                part: 'full',
                serverSeq: 20,
                payload: _fullBytes(
                  id: 't1',
                  title: 'Buy oat milk',
                  done: false,
                  deleted: false,
                ),
              ),
            ],
            nextCursor: 20,
          );
        }
        return PullPage(envelopes: const [], nextCursor: since);
      };
      await h.client.syncOnce();

      expect(h.domain['t1']!.title, 'Buy oat milk');
      expect(h.domain['t1']!.deleted, isTrue);
      expect(
        h.deletedWritesFromFullApply.first,
        0,
        reason: 'apply of full does not write deleted',
      );
    },
  );

  test(
    'unknown part without applyPart advances the cursor and does not throw',
    () async {
      final h = await _Harness.open(includePartCallbacks: false);
      await h.client.write<void>(
        entityType: 'task',
        id: 't1',
        persist: () async {
          h.domain['t1'] = _Task(id: 't1', title: 'Buy milk');
        },
      );
      h.fake.onPull = ({required int since, int? limit}) async {
        if (since == 0) {
          return PullPage(
            envelopes: [
              _partEnvelope(
                id: 't1',
                part: 'starred',
                serverSeq: 7,
                payload: _flagBytes(true),
              ),
            ],
            nextCursor: 7,
          );
        }
        return PullPage(envelopes: const [], nextCursor: since);
      };

      final report = await h.client.syncOnce();
      expect(report.cursor, 7);
      expect(await h.store.readCursor('alice'), 7);
      expect(h.domain['t1']!.title, 'Buy milk');
      expect(h.domain['t1']!.done, isFalse);
      expect(h.domain['t1']!.deleted, isFalse);
      final starred = await h.stateOf('t1', part: 'starred');
      expect(starred, isNotNull);
      expect(starred!.dirty, isFalse);
    },
  );

  test('encodePart returning null clears dirty and does not POST', () async {
    var encodeCalls = 0;
    final h = await _Harness.open(
      encodePart: (id, part) async {
        encodeCalls++;
        expect(id, 't1');
        expect(part, 'done');
        return null;
      },
    );
    await h.client.write<void>(
      entityType: 'task',
      id: 't1',
      part: 'done',
      persist: () async {
        h.domain['t1'] = _Task(id: 't1', done: true);
      },
    );
    expect((await h.stateOf('t1', part: 'done'))!.dirty, isTrue);

    final report = await h.client.syncOnce();
    expect(encodeCalls, 1);
    expect(h.fake.pushCalls, isEmpty);
    expect(report.pushed, 0);
    expect((await h.stateOf('t1', part: 'done'))!.dirty, isFalse);
  });

  test(
    'write with a blank part is ArgumentError and persist does not run',
    () async {
      final h = await _Harness.open();
      var persistCalled = false;
      expect(
        () => h.client.write<void>(
          entityType: 'task',
          id: 't1',
          part: '  ',
          persist: () async {
            persistCalled = true;
          },
        ),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'part')),
      );
      expect(persistCalled, isFalse);
    },
  );
}
